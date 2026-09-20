# pay-escrow

The on-chain half of Çek (P2P cheque) and Havuz (pool). See `src/lib.rs`'s
module docs for why the whole cheque lifecycle — including the pre-signed
"zorla tahsil" (force collect) path — lives in one Soroban contract instead
of splitting it with classic Claimable Balance.

## Build & test

```sh
cargo test                                # 17 tests, no network needed
cargo build --target wasm32v1-none --release
```

**Gotcha:** build for `wasm32v1-none`, not `wasm32-unknown-unknown`. Rust
1.82+ turns on WASM reference-types by default for `wasm32-unknown-unknown`,
which the Soroban host does not support yet —
`stellar contract deploy` fails with `HostError: Error(WasmVm,
InvalidAction)` / `reference-types not enabled` if you build for the wrong
target. `wasm32v1-none` is the target Soroban's toolchain actually expects
(`rustup target add wasm32v1-none` once).

## Deploy (testnet)

```sh
stellar keys generate deployer --network testnet
curl "https://friendbot.stellar.org/?addr=$(stellar keys address deployer)"
stellar contract deploy \
  --wasm target/wasm32v1-none/release/pay_escrow.wasm \
  --source deployer \
  --network testnet
```

**Deployed instance (testnet, 2026-09-19):**
`PAY_ESCROW_CONTRACT_ID=CDD7FWHQIAF2Z57CMZUO5BT4TY4VTIZKXLYD4WKQ7HDLO5IQOYU6V3ID`
([stellar.expert](https://stellar.expert/explorer/testnet/contract/CDD7FWHQIAF2Z57CMZUO5BT4TY4VTIZKXLYD4WKQ7HDLO5IQOYU6V3ID)) —
already set in `deploy/.env`. Redeploying (e.g. after a contract code
change) produces a new id; update `deploy/.env`'s `PAY_ESCROW_CONTRACT_ID`
accordingly.

The asset it holds is the anchor's SAC (Stellar Asset Contract) address.
For the MVP asset (TR Mock Anchor's testnet USDC,
`GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5`):

```sh
stellar contract id asset \
  --asset USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5 \
  --network testnet
# -> CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA (ASSET_SAC_CONTRACT_ID)
```

This command only *computes* the deterministic SAC address — it does not
require the wrapper contract to already exist. If it isn't instantiated
yet, run `stellar contract asset deploy --asset USDC:<issuer> --source
deployer --network testnet` once (ours already existed on testnet — some
other holder had triggered it first, which is expected and harmless).
See `docs/reference/platform/anchor-entegrasyonu.md`.

## Function reference

| Function | Caller | Auth | Notes |
|---|---|---|---|
| `lock` | sender | sender | Writes + funds a cheque in one call |
| `claim` | receiver | receiver | Requires `now < expires_at` |
| `refund` | anyone | none (permissionless) | Requires `now >= expires_at` |
| `force_collect` | receiver | sender (pre-signed auth entry) | Only in the last 24h before `expires_at`; bounces instead of reverting on insufficient balance |
| `deposit` | owner | owner | Always allowed |
| `withdraw` | owner | owner | Always allowed, limited by the recorded pool balance |
| `bump_instance` | anyone | none | TTL housekeeping, called by pay-scheduler-service |

Pool withdrawals have no time lock. The contract has no upgrade path, so
changing this source affects newly deployed contracts only. A contract
already deployed with the former seven-day rule will keep enforcing that rule
for its existing pool balances until each balance's original unlock time.
