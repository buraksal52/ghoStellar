# pay-escrow

The on-chain half of Çek (P2P cheque) and Havuz (pool). See `src/lib.rs`'s
module docs for why the whole cheque lifecycle — including the pre-signed
"zorla tahsil" (force collect) path — lives in one Soroban contract instead
of splitting it with classic Claimable Balance.

## Build & test

```sh
cargo test                                        # 17 tests, no network needed
cargo build --target wasm32-unknown-unknown --release
```

## Deploy (testnet)

```sh
stellar keys generate deployer --network testnet --fund
stellar contract deploy \
  --wasm target/wasm32-unknown-unknown/release/pay_escrow.wasm \
  --source deployer \
  --network testnet
```

The printed contract id (`C...`) is `PAY_ESCROW_CONTRACT_ID` in
`deploy/env/example.env`. The asset it holds is the anchor's SAC (Stellar
Asset Contract) address for the MVP asset — see the plan's Açık Varsayım #1
and `docs/reference/platform/anchor-entegrasyonu.md`.

## Function reference

| Function | Caller | Auth | Notes |
|---|---|---|---|
| `lock` | sender | sender | Writes + funds a cheque in one call |
| `claim` | receiver | receiver | Requires `now < expires_at` |
| `refund` | anyone | none (permissionless) | Requires `now >= expires_at` |
| `force_collect` | receiver | sender (pre-signed auth entry) | Only in the last 24h before `expires_at`; bounces instead of reverting on insufficient balance |
| `deposit` | owner | owner | Always allowed; resets the withdraw lock |
| `withdraw` | owner | owner | Requires `now >= last_deposit_at + 1 week` |
| `bump_instance` | anyone | none | TTL housekeeping, called by pay-scheduler-service |
