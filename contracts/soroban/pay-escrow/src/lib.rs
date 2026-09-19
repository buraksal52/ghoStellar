//! pay-escrow — the on-chain half of "Çek" (P2P cheque) and "Havuz" (pool
//! deposit) for Local-Payment.
//!
//! # Why one contract holds both the cheque and the pre-authorized "zorla
//! tahsil" (force collect), instead of Claimable Balance + Soroban escrow
//! together
//!
//! `docs/reference/platform/p2p-cek-ve-havuz-mimarisi.md` §2 sketches
//! splitting the cheque's "waiting in the pool" state onto classic
//! Claimable Balance and only the pre-auth/force-collect condition onto a
//! Soroban contract, leaving the exact division an open assumption (§10.1).
//! That split doesn't work once force-collect ships: §5's condition 2
//! ("the pool was never funded") has to be verified *on chain, by the
//! contract* ("backend'e güvenilmez") — but a Soroban contract cannot read
//! classic Claimable Balance ledger state. Splitting the two mechanisms
//! would force that check back onto the backend, breaking D6 (chain is the
//! authority) and D1 (the same amount is never "live" in two places at
//! once) from the same doc's §3. So here, the *entire* cheque lifecycle —
//! funding, claim, timeout refund, and force-collect — lives in this one
//! contract's storage, and classic Claimable Balance is not used for
//! cheques in this MVP (see the plan's "Kritik Mimari Karar").
//!
//! # The "already funded?" question, without a pre-declare step
//!
//! `force_collect` has to work even when `lock` was **never called** (the
//! sender went offline before funding). So it cannot look anything up from
//! a stored record in that case — there isn't one. Instead the receiver
//! submits `force_collect` with the cheque's terms as plain arguments
//! (`sender`, `receiver`, `token`, `amount`, `expires_at`), authorized by a
//! `SorobanAuthorizationEntry` the sender pre-signed for this *exact*
//! invocation (contract id + function name + these exact argument values)
//! back when the cheque was written — Soroban's own auth-entry binding does
//! the "did the sender really agree to this?" check, so the contract does
//! not need a pre-existing record to trust the inputs. The contract's own
//! job is narrower: has this `cheque_id` already been used by *any* path
//! (`lock`, or an earlier `force_collect`)? If so, refuse — that is what
//! makes "funded" and "already collected" mutually exclusive (D1) and
//! keeps `force_collect` from ever running twice for the same cheque (D5').
//!
//! # What this contract deliberately does not do
//!
//! No partial amounts (D8), no re-opening a terminal cheque (D4), no
//! multi-asset accounting beyond what each cheque/pool row itself records,
//! no interest, no fees beyond the network's own, no upgradeability.

#![no_std]

use soroban_sdk::{contract, contracterror, contractimpl, contracttype, token, Address, BytesN, Env};

/// A cheque's terms are valid for one week (p2p doc §0 rule 2 / §9.H1).
pub const CHEQUE_VALIDITY_SECONDS: u64 = 7 * 24 * 60 * 60;

/// A pool deposit re-locks withdrawal for one week from the *last* deposit
/// (p2p doc §7 / §9.H2) — enforced here as an absolute deadline, not a
/// duration a client could misreport.
pub const POOL_LOCK_SECONDS: u64 = 7 * 24 * 60 * 60;

/// force_collect only becomes callable in the last 24h before a cheque
/// expires (plan's open assumption #5, answering p2p doc §10 G5): it exists
/// to rescue a cheque the sender is about to let lapse, not to race ahead of
/// a sender who still has days left to fund it (G5 abuse case).
pub const FORCE_COLLECT_WINDOW_SECONDS: u64 = 24 * 60 * 60;

const INSTANCE_BUMP_LEDGERS: u32 = 120_960; // ~7 days at ~5s/ledger
const PERSISTENT_BUMP_LEDGERS: u32 = 622_080; // ~36 days — outlives a cheque's own 7-day life with margin

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[contracttype]
pub enum ChequeState {
    Funded,
    Claimed,
    Refunded,
    Collected,
    Bounced,
}

#[derive(Clone)]
#[contracttype]
pub struct ChequeRecord {
    pub sender: Address,
    pub receiver: Address,
    pub token: Address,
    pub amount: i128,
    pub expires_at: u64, // unix seconds, from env.ledger().timestamp() — D7
    pub state: ChequeState,
}

#[derive(Clone)]
#[contracttype]
pub struct PoolRecord {
    pub token: Address,
    pub amount: i128,
    pub last_deposit_at: u64, // unix seconds; withdraw's 1-week clock (§9.H2)
}

#[derive(Clone)]
#[contracttype]
pub enum DataKey {
    Cheque(BytesN<16>), // 16 raw bytes of a ULID cheque id
    Pool(Address),
}

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    InvalidAmount = 1,      // A6: zero or negative amount
    SelfTransfer = 2,       // A5: sender == receiver
    ChequeAlreadyUsed = 3,  // lock() called twice for the same cheque_id
    ChequeNotFound = 4,     // claim/refund on an id with no Funded record
    ChequeNotFunded = 5,    // claim/refund on a record that isn't Funded
    ChequeExpired = 6,      // claim after expires_at
    ChequeNotExpired = 7,   // refund before expires_at
    AlreadyFunded = 8,      // force_collect while a Funded record exists — claim() applies instead
    AlreadyTerminal = 9,    // force_collect after this cheque already resolved one way or another
    ForceCollectTooEarly = 10, // before the last-24h window (G5)
    ForceCollectTooLate = 11,  // at/after expires_at
    WithdrawLocked = 12,    // pool withdraw before last_deposit_at + 1 week
    InsufficientPoolBalance = 13,
    MixedAsset = 14, // deposit() called with a different token than the pool already holds
}

#[contract]
pub struct PayEscrow;

#[contractimpl]
impl PayEscrow {
    // ---- Çek (cheque) ----------------------------------------------------

    /// Writes and funds a cheque in one atomic call: pulls `amount` of
    /// `token` from `sender` into this contract's custody and records the
    /// cheque as `Funded`. This is the on-chain moment the off-chain state
    /// machine calls IMZALI(rezerve) -> FONLANIYOR -> HAVUZDA (p2p doc §4).
    pub fn lock(
        e: Env,
        sender: Address,
        cheque_id: BytesN<16>,
        receiver: Address,
        token: Address,
        amount: i128,
        expires_at: u64,
    ) -> Result<(), Error> {
        sender.require_auth();

        if amount <= 0 {
            return Err(Error::InvalidAmount);
        }
        if sender == receiver {
            return Err(Error::SelfTransfer);
        }

        let key = DataKey::Cheque(cheque_id.clone());
        if e.storage().persistent().has(&key) {
            return Err(Error::ChequeAlreadyUsed);
        }

        let token_client = token::Client::new(&e, &token);
        token_client.transfer(&sender, &e.current_contract_address(), &amount);

        let record = ChequeRecord {
            sender,
            receiver,
            token,
            amount,
            expires_at,
            state: ChequeState::Funded,
        };
        e.storage().persistent().set(&key, &record);
        e.storage()
            .persistent()
            .extend_ttl(&key, PERSISTENT_BUMP_LEDGERS / 2, PERSISTENT_BUMP_LEDGERS);

        e.events().publish((symbol_lock(), record.sender.clone()), cheque_id);
        Ok(())
    }

    /// Pays the cheque's receiver out of this contract's custody. Requires
    /// the receiver's own authorization (this is the "Al" / claim step, p2p
    /// doc §6.1) and that the cheque has not expired.
    pub fn claim(e: Env, cheque_id: BytesN<16>) -> Result<(), Error> {
        let key = DataKey::Cheque(cheque_id.clone());
        let mut record: ChequeRecord = e
            .storage()
            .persistent()
            .get(&key)
            .ok_or(Error::ChequeNotFound)?;

        if record.state != ChequeState::Funded {
            return Err(Error::ChequeNotFunded);
        }
        record.receiver.require_auth();

        let now = e.ledger().timestamp();
        if now >= record.expires_at {
            return Err(Error::ChequeExpired);
        }

        let token_client = token::Client::new(&e, &record.token);
        token_client.transfer(&e.current_contract_address(), &record.receiver, &record.amount);

        record.state = ChequeState::Claimed;
        e.storage().persistent().set(&key, &record);
        e.events().publish((symbol_claim(), record.receiver), cheque_id);
        Ok(())
    }

    /// Returns an expired, never-claimed cheque's funds to its sender.
    /// Deliberately **permissionless** (no `require_auth` on the caller) —
    /// D9: nobody has to wait on the sender's or receiver's presence for
    /// money to stop being stuck. `pay-scheduler-service` calls this on a
    /// sweep, but any third party could just as well.
    pub fn refund(e: Env, cheque_id: BytesN<16>) -> Result<(), Error> {
        let key = DataKey::Cheque(cheque_id.clone());
        let mut record: ChequeRecord = e
            .storage()
            .persistent()
            .get(&key)
            .ok_or(Error::ChequeNotFound)?;

        if record.state != ChequeState::Funded {
            return Err(Error::ChequeNotFunded);
        }
        let now = e.ledger().timestamp();
        if now < record.expires_at {
            return Err(Error::ChequeNotExpired);
        }

        let token_client = token::Client::new(&e, &record.token);
        token_client.transfer(&e.current_contract_address(), &record.sender, &record.amount);

        record.state = ChequeState::Refunded;
        e.storage().persistent().set(&key, &record);
        e.events().publish((symbol_refund(), record.sender), cheque_id);
        Ok(())
    }

    /// Lets the receiver pull the cheque's amount directly from the
    /// sender's own balance when the sender never funded the cheque at all
    /// — p2p doc §5/§6.3. `sender` must have pre-signed a
    /// `SorobanAuthorizationEntry` for this exact invocation (all six
    /// arguments, expiring no later than `expires_at`) when the cheque was
    /// written; `sender.require_auth()` below is what checks that entry.
    ///
    /// If the sender's balance is short (D2 says this should be rare — the
    /// balance was reserved when the cheque was signed — but accounts can
    /// still be closed or trustlines removed out from under a reservation),
    /// this does **not** revert: it records the cheque as `Bounced` and
    /// moves nothing, so the sender is never left in debt (D2, D8) — only
    /// the cheque itself fails.
    pub fn force_collect(
        e: Env,
        sender: Address,
        cheque_id: BytesN<16>,
        receiver: Address,
        token: Address,
        amount: i128,
        expires_at: u64,
    ) -> Result<ChequeState, Error> {
        sender.require_auth();

        let key = DataKey::Cheque(cheque_id.clone());
        if let Some(existing) = e.storage().persistent().get::<DataKey, ChequeRecord>(&key) {
            return Err(match existing.state {
                ChequeState::Funded => Error::AlreadyFunded,
                _ => Error::AlreadyTerminal,
            });
        }

        let now = e.ledger().timestamp();
        if now >= expires_at {
            return Err(Error::ForceCollectTooLate);
        }
        if expires_at - now > FORCE_COLLECT_WINDOW_SECONDS {
            return Err(Error::ForceCollectTooEarly);
        }
        if amount <= 0 {
            return Err(Error::InvalidAmount);
        }

        let token_client = token::Client::new(&e, &token);
        let sender_balance = token_client.balance(&sender);

        let final_state = if sender_balance >= amount {
            token_client.transfer(&sender, &receiver, &amount);
            ChequeState::Collected
        } else {
            ChequeState::Bounced
        };

        let record = ChequeRecord {
            sender,
            receiver,
            token,
            amount,
            expires_at,
            state: final_state,
        };
        e.storage().persistent().set(&key, &record);
        e.storage()
            .persistent()
            .extend_ttl(&key, PERSISTENT_BUMP_LEDGERS / 2, PERSISTENT_BUMP_LEDGERS);

        let event_topic = match final_state {
            ChequeState::Collected => symbol_collected(),
            _ => symbol_bounced(),
        };
        e.events().publish((event_topic, record.sender), cheque_id);
        Ok(final_state)
    }

    pub fn get_cheque(e: Env, cheque_id: BytesN<16>) -> Option<ChequeRecord> {
        e.storage().persistent().get(&DataKey::Cheque(cheque_id))
    }

    // ---- Havuz (pool) ------------------------------------------------------

    /// Adds to `owner`'s pool balance. Always free (p2p doc §7) — but it
    /// resets the withdrawal clock to *now*, exactly as documented, so a
    /// deposit while a countdown is already running restarts it.
    pub fn deposit(e: Env, owner: Address, token: Address, amount: i128) -> Result<(), Error> {
        owner.require_auth();
        if amount <= 0 {
            return Err(Error::InvalidAmount);
        }

        let key = DataKey::Pool(owner.clone());
        let mut record: PoolRecord = e.storage().persistent().get(&key).unwrap_or(PoolRecord {
            token: token.clone(),
            amount: 0,
            last_deposit_at: 0,
        });
        if record.amount > 0 && record.token != token {
            return Err(Error::MixedAsset);
        }

        let token_client = token::Client::new(&e, &token);
        token_client.transfer(&owner, &e.current_contract_address(), &amount);

        record.token = token;
        record.amount += amount;
        record.last_deposit_at = e.ledger().timestamp();
        e.storage().persistent().set(&key, &record);
        e.storage()
            .persistent()
            .extend_ttl(&key, PERSISTENT_BUMP_LEDGERS / 2, PERSISTENT_BUMP_LEDGERS);

        e.events().publish((symbol_deposit(), owner), record.amount);
        Ok(())
    }

    /// Withdraws from `owner`'s pool balance. Rejected on-chain — not just
    /// by the backend — until at least one week has passed since the last
    /// `deposit` (p2p doc §7 / §9.H2): "backend'e güvenilmez" applies here
    /// exactly as it does to force_collect's conditions.
    pub fn withdraw(e: Env, owner: Address, amount: i128) -> Result<(), Error> {
        owner.require_auth();
        if amount <= 0 {
            return Err(Error::InvalidAmount);
        }

        let key = DataKey::Pool(owner.clone());
        let mut record: PoolRecord = e
            .storage()
            .persistent()
            .get(&key)
            .ok_or(Error::InsufficientPoolBalance)?;

        if amount > record.amount {
            return Err(Error::InsufficientPoolBalance);
        }
        let now = e.ledger().timestamp();
        if now < record.last_deposit_at + POOL_LOCK_SECONDS {
            return Err(Error::WithdrawLocked);
        }

        let token_client = token::Client::new(&e, &record.token);
        token_client.transfer(&e.current_contract_address(), &owner, &amount);

        record.amount -= amount;
        e.storage().persistent().set(&key, &record);

        e.events().publish((symbol_withdraw(), owner), amount);
        Ok(())
    }

    pub fn get_pool(e: Env, owner: Address) -> Option<PoolRecord> {
        e.storage().persistent().get(&DataKey::Pool(owner))
    }

    /// Bumps this contract instance's own storage TTL. Called periodically
    /// by `pay-scheduler-service`; a contract cannot extend its own instance
    /// TTL from inside a user-triggered call without adding unrelated gas
    /// cost to every cheque/pool operation, so it gets a dedicated entry
    /// point instead.
    pub fn bump_instance(e: Env) {
        e.storage().instance().extend_ttl(INSTANCE_BUMP_LEDGERS, INSTANCE_BUMP_LEDGERS);
    }
}

fn symbol_lock() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("lock")
}
fn symbol_claim() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("claim")
}
fn symbol_refund() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("refund")
}
fn symbol_collected() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("collected")
}
fn symbol_bounced() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("bounced")
}
fn symbol_deposit() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("deposit")
}
fn symbol_withdraw() -> soroban_sdk::Symbol {
    soroban_sdk::symbol_short!("withdraw")
}

#[cfg(test)]
mod test;
