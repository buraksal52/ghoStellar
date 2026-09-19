#![cfg(test)]
//! Exercises the p2p doc's §9 case catalog for the entries that land on the
//! chain side of the state machine (see lib.rs module docs and the plan's
//! "Test: src/test.rs" note): A5/A6 (reject at write time), C5/C6 (claim vs
//! refund/claim races), D1'/D5'/D7' (force_collect's guards), and H2 (pool
//! withdraw lock).

use super::*;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    Env,
};

const DAY: u64 = 24 * 60 * 60;
const WEEK: u64 = 7 * DAY;

fn setup(e: &Env) -> (PayEscrowClient<'_>, Address, Address) {
    let contract_id = e.register(PayEscrow, ());
    let client = PayEscrowClient::new(e, &contract_id);
    let token_admin = Address::generate(e);
    let token = e.register_stellar_asset_contract_v2(token_admin.clone());
    (client, token.address(), token_admin)
}

fn mint(e: &Env, token_id: &Address, to: &Address, amount: i128) {
    soroban_sdk::token::StellarAssetClient::new(e, token_id).mint(to, &amount);
}

fn balance(e: &Env, token_id: &Address, of: &Address) -> i128 {
    soroban_sdk::token::Client::new(e, token_id).balance(of)
}

fn cheque_id(e: &Env, tag: u8) -> BytesN<16> {
    let mut bytes = [0u8; 16];
    bytes[15] = tag;
    BytesN::from_array(e, &bytes)
}

// ---- 9.A Oluşturma (write-time rejection) ---------------------------------

#[test]
fn a5_self_transfer_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let user = Address::generate(&e);
    mint(&e, &token_id, &user, 1_000);

    let result = client.try_lock(&user, &cheque_id(&e, 1), &user, &token_id, &500, &(e.ledger().timestamp() + WEEK));
    assert_eq!(result, Err(Ok(Error::SelfTransfer)));
}

#[test]
fn a6_zero_amount_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);

    let result = client.try_lock(&sender, &cheque_id(&e, 1), &receiver, &token_id, &0, &(e.ledger().timestamp() + WEEK));
    assert_eq!(result, Err(Ok(Error::InvalidAmount)));
}

#[test]
fn g2_same_cheque_id_twice_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let expires = e.ledger().timestamp() + WEEK;
    let id = cheque_id(&e, 1);

    client.lock(&sender, &id, &receiver, &token_id, &500, &expires);
    let result = client.try_lock(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(result, Err(Ok(Error::ChequeAlreadyUsed)));
}

// ---- 6.1 Mutlu yol ----------------------------------------------------

#[test]
fn happy_path_lock_then_claim() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let expires = e.ledger().timestamp() + WEEK;
    let id = cheque_id(&e, 1);

    client.lock(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(balance(&e, &token_id, &sender), 500);
    assert_eq!(client.get_cheque(&id).unwrap().state, ChequeState::Funded);

    client.claim(&id);
    assert_eq!(balance(&e, &token_id, &receiver), 500);
    assert_eq!(client.get_cheque(&id).unwrap().state, ChequeState::Claimed);
}

// ---- 9.C Talep (claim) — C5, C6 ----------------------------------------

#[test]
fn c5_claim_after_expiry_rejected_refund_after_expiry_succeeds() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let start = e.ledger().timestamp();
    let expires = start + WEEK;
    let id = cheque_id(&e, 1);
    client.lock(&sender, &id, &receiver, &token_id, &500, &expires);

    e.ledger().set_timestamp(expires); // exactly at expiry: claim window closed

    let claim_result = client.try_claim(&id);
    assert_eq!(claim_result, Err(Ok(Error::ChequeExpired)));

    client.refund(&id);
    assert_eq!(balance(&e, &token_id, &sender), 1_000);
    assert_eq!(client.get_cheque(&id).unwrap().state, ChequeState::Refunded);
}

#[test]
fn c6_double_claim_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let id = cheque_id(&e, 1);
    client.lock(&sender, &id, &receiver, &token_id, &500, &(e.ledger().timestamp() + WEEK));

    client.claim(&id);
    let second = client.try_claim(&id);
    assert_eq!(second, Err(Ok(Error::ChequeNotFunded)));
}

#[test]
fn refund_before_expiry_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let id = cheque_id(&e, 1);
    client.lock(&sender, &id, &receiver, &token_id, &500, &(e.ledger().timestamp() + WEEK));

    let result = client.try_refund(&id);
    assert_eq!(result, Err(Ok(Error::ChequeNotExpired)));
}

// ---- 9.D Zorla Tahsil ---------------------------------------------------

#[test]
fn d2_force_collect_succeeds_when_never_funded_and_balance_sufficient() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let now = e.ledger().timestamp();
    let expires = now + 12 * 60 * 60; // 12h out: inside the 24h window
    let id = cheque_id(&e, 1);

    let state = client.force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(state, ChequeState::Collected);
    assert_eq!(balance(&e, &token_id, &receiver), 500);
    assert_eq!(balance(&e, &token_id, &sender), 500);
}

#[test]
fn d3_force_collect_bounces_without_reverting_when_balance_short() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 100); // less than the cheque amount
    let now = e.ledger().timestamp();
    let expires = now + 12 * 60 * 60;
    let id = cheque_id(&e, 1);

    let state = client.force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(state, ChequeState::Bounced);
    // D2/D8: sender keeps what they had; nothing moved; not left "in debt".
    assert_eq!(balance(&e, &token_id, &sender), 100);
    assert_eq!(balance(&e, &token_id, &receiver), 0);
}

#[test]
fn d1_force_collect_rejected_when_already_funded() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let now = e.ledger().timestamp();
    let expires = now + 12 * 60 * 60;
    let id = cheque_id(&e, 1);

    client.lock(&sender, &id, &receiver, &token_id, &500, &expires);
    let result = client.try_force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(result, Err(Ok(Error::AlreadyFunded)));
}

#[test]
fn d5_force_collect_cannot_run_twice() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let now = e.ledger().timestamp();
    let expires = now + 12 * 60 * 60;
    let id = cheque_id(&e, 1);

    client.force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    let second = client.try_force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(second, Err(Ok(Error::AlreadyTerminal)));
}

#[test]
fn g5_force_collect_too_early_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let now = e.ledger().timestamp();
    let expires = now + WEEK; // far in the future — outside the 24h window
    let id = cheque_id(&e, 1);

    let result = client.try_force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(result, Err(Ok(Error::ForceCollectTooEarly)));
}

#[test]
fn force_collect_at_or_after_expiry_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let expires = e.ledger().timestamp();
    let id = cheque_id(&e, 1);

    let result = client.try_force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(result, Err(Ok(Error::ForceCollectTooLate)));
}

#[test]
fn d7_funding_wins_the_race_against_force_collect() {
    // The sender comes back online just in time and funds normally; a
    // force_collect attempt for the same id after that must see
    // AlreadyFunded, not silently double-spend the cheque.
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let sender = Address::generate(&e);
    let receiver = Address::generate(&e);
    mint(&e, &token_id, &sender, 1_000);
    let now = e.ledger().timestamp();
    let expires = now + 12 * 60 * 60;
    let id = cheque_id(&e, 1);

    client.lock(&sender, &id, &receiver, &token_id, &500, &expires);
    let result = client.try_force_collect(&sender, &id, &receiver, &token_id, &500, &expires);
    assert_eq!(result, Err(Ok(Error::AlreadyFunded)));
    assert_eq!(client.get_cheque(&id).unwrap().state, ChequeState::Funded);
}

// ---- 9.H Süre / Havuz ---------------------------------------------------

#[test]
fn h2_pool_withdraw_locked_for_one_week_after_last_deposit() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let owner = Address::generate(&e);
    mint(&e, &token_id, &owner, 1_000);

    client.deposit(&owner, &token_id, &300);
    let too_early = client.try_withdraw(&owner, &100);
    assert_eq!(too_early, Err(Ok(Error::WithdrawLocked)));

    e.ledger().set_timestamp(e.ledger().timestamp() + WEEK);
    client.withdraw(&owner, &100);
    assert_eq!(balance(&e, &token_id, &owner), 800); // 1000 - 300 + 100
    assert_eq!(client.get_pool(&owner).unwrap().amount, 200);
}

#[test]
fn h2_deposit_resets_the_lock_clock() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let owner = Address::generate(&e);
    mint(&e, &token_id, &owner, 1_000);

    client.deposit(&owner, &token_id, &300);
    e.ledger().set_timestamp(e.ledger().timestamp() + WEEK - DAY); // almost unlocked
    client.deposit(&owner, &token_id, &100); // resets the clock (§7)

    e.ledger().set_timestamp(e.ledger().timestamp() + DAY + 1); // would have been unlocked under the OLD clock
    let result = client.try_withdraw(&owner, &50);
    assert_eq!(result, Err(Ok(Error::WithdrawLocked)));
}

#[test]
fn withdraw_more_than_balance_rejected() {
    let e = Env::default();
    e.mock_all_auths();
    let (client, token_id, _admin) = setup(&e);
    let owner = Address::generate(&e);
    mint(&e, &token_id, &owner, 1_000);

    client.deposit(&owner, &token_id, &300);
    e.ledger().set_timestamp(e.ledger().timestamp() + WEEK);
    let result = client.try_withdraw(&owner, &301);
    assert_eq!(result, Err(Ok(Error::InsufficientPoolBalance)));
}
