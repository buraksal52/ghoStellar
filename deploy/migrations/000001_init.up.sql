-- ghoStellar MVP schema. Chain is the single source of truth (D6,
-- docs/reference/platform/architecture.md §8); every table here is a
-- derived cache and carries ledger_seq so it can be rebuilt from the chain.
-- Up-only, every statement idempotent (IF NOT EXISTS) — see architecture.md
-- §14 / the plan's GOTCHA'lar.

CREATE SCHEMA IF NOT EXISTS pay;

CREATE TABLE IF NOT EXISTS pay.users (
    id              BIGSERIAL PRIMARY KEY,
    stellar_address VARCHAR(56) NOT NULL UNIQUE,
    display_name    TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Money is NUMERIC(40,0) raw + a separate decimals column, never
-- DOUBLE PRECISION (architecture.md §7 / GOTCHA'lar).
CREATE TABLE IF NOT EXISTS pay.cheques (
    id                  CHAR(26) PRIMARY KEY,       -- ULID
    sender_address      VARCHAR(56) NOT NULL,
    receiver_address    VARCHAR(56) NOT NULL,
    token_contract      VARCHAR(56) NOT NULL,
    amount_raw          NUMERIC(40,0) NOT NULL,
    decimals            SMALLINT NOT NULL,
    state               TEXT NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    lock_tx_hash        TEXT,
    preauth_entry_xdr   TEXT,                       -- sender's pre-signed force_collect auth entry
    ledger_seq          BIGINT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (amount_raw > 0),
    CHECK (sender_address <> receiver_address)
);

CREATE INDEX IF NOT EXISTS idx_cheques_sender ON pay.cheques (sender_address);
CREATE INDEX IF NOT EXISTS idx_cheques_receiver ON pay.cheques (receiver_address);
CREATE INDEX IF NOT EXISTS idx_cheques_state_expiry ON pay.cheques (state, expires_at);

-- D3: a chain event (reorg/replay) or a duplicated client action never
-- applies the same (cheque, from, to) transition twice.
CREATE TABLE IF NOT EXISTS pay.cheque_transitions (
    id          BIGSERIAL PRIMARY KEY,
    cheque_id   CHAR(26) NOT NULL REFERENCES pay.cheques(id),
    from_state  TEXT NOT NULL,
    to_state    TEXT NOT NULL,
    cause       TEXT NOT NULL,   -- e.g. "user_action", "scheduler_sweep", "chain_sync"
    tx_hash     TEXT,
    ledger_seq  BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (cheque_id, from_state, to_state)
);

-- D5: at most one active outgoing cheque per sender. Enforced by a partial
-- unique index, not application logic alone — a second concurrent request
-- hits a constraint violation, not a race.
CREATE TABLE IF NOT EXISTS pay.reservations (
    cheque_id   CHAR(26) PRIMARY KEY REFERENCES pay.cheques(id),
    account     VARCHAR(56) NOT NULL,
    amount_raw  NUMERIC(40,0) NOT NULL,
    state       TEXT NOT NULL DEFAULT 'active' -- active | released
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_reservations_active_account
    ON pay.reservations (account)
    WHERE state = 'active';

CREATE TABLE IF NOT EXISTS pay.pool_deposits (
    id                  BIGSERIAL PRIMARY KEY,
    owner_address       VARCHAR(56) NOT NULL,
    amount_raw          NUMERIC(40,0) NOT NULL,
    decimals            SMALLINT NOT NULL,
    last_deposit_ledger BIGINT,
    ledger_seq          BIGINT,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pool_deposits_owner ON pay.pool_deposits (owner_address);
-- D5 for the pool side (one in-flight deposit/withdraw per owner): the one
-- row per owner this unique index guarantees is locked with
-- `SELECT ... FOR UPDATE` for the duration of building+recording an
-- operation, which serializes concurrent requests without a second table.

-- Shared by every service that accepts money-moving POSTs
-- (architecture.md §10: Idempotency-Key on every such request, 24h TTL).
-- stellar_address, not a users(id) FK: "hiçbir servis başka bir servisin
-- tablosunu okumaz" (architecture.md §4 rule 1) — pay.users belongs to
-- pay-auth-service alone, even though this MVP's single Postgres instance
-- makes the schema technically reachable. Identity crosses service
-- boundaries as the address carried in the JWT, never as a foreign key.
CREATE TABLE IF NOT EXISTS pay.idempotency_keys (
    key             TEXT PRIMARY KEY,
    stellar_address VARCHAR(56) NOT NULL,
    request_hash    TEXT NOT NULL,
    response_json   JSONB,
    status          TEXT NOT NULL DEFAULT 'pending', -- pending | done
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours'
);

-- pay-tx-service's own submission ledger: every signed XDR it ever
-- forwarded to pay-chain-gateway, keyed by the same Idempotency-Key the
-- caller used, regardless of which domain (cheque, pool, anchor withdraw)
-- it came from — "yalnızca tx-service submit eder" (architecture.md §4).
CREATE TABLE IF NOT EXISTS pay.submissions (
    idempotency_key TEXT PRIMARY KEY,
    stellar_address VARCHAR(56) NOT NULL,
    purpose         TEXT NOT NULL, -- cheque.lock | cheque.claim | cheque.refund | cheque.force_collect | pool.deposit | pool.withdraw | anchor.withdraw_payment | auth.trustline
    tx_hash         TEXT,
    state           TEXT NOT NULL DEFAULT 'pending', -- pending | submitted | success | failed
    result_code     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Anchor JWTs are never stored here (custody decision, see
-- docs/reference/platform/anchor-entegrasyonu.md) — this is a transaction
-- ledger only.
CREATE TABLE IF NOT EXISTS pay.anchor_transactions (
    id              TEXT PRIMARY KEY,   -- the anchor's own SEP-24 transaction id
    anchor_id       TEXT NOT NULL,
    stellar_address VARCHAR(56) NOT NULL,
    kind            TEXT NOT NULL,      -- deposit | withdraw
    state           TEXT NOT NULL,      -- SEP-24 status vocabulary, self-reported by the client
    amount_raw      NUMERIC(40,0),
    decimals        SMALLINT,
    stellar_tx_hash TEXT,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_anchor_tx_address ON pay.anchor_transactions (stellar_address);

-- Derived/cached trustline state; always re-verified against the chain
-- before a cheque/deposit is allowed to proceed (D6).
CREATE TABLE IF NOT EXISTS pay.trustlines (
    stellar_address VARCHAR(56) NOT NULL,
    asset_code      TEXT NOT NULL,
    asset_issuer    VARCHAR(56) NOT NULL,
    state           TEXT NOT NULL, -- unknown | missing | active
    ledger_seq      BIGINT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (stellar_address, asset_code, asset_issuer)
);

-- Append-only audit trail (architecture.md §11): quote/XDR production,
-- submissions, risk rejections. Never updated, never deleted.
CREATE TABLE IF NOT EXISTS pay.audit_log (
    id          BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ledger_seq  BIGINT,
    actor       TEXT NOT NULL,   -- stellar address or "system"
    action      TEXT NOT NULL,   -- e.g. "cheque.lock_xdr_issued"
    details     JSONB
);
