# Local-Payment

Stellar üzerinde non-custodial P2P ödeme MVP'si: kişiden kişiye "Çek"
gönderimi, "Havuz" mevduatı, bir anchor üzerinden fiat giriş/çıkışı. Bkz.
[`CLAUDE.md`](CLAUDE.md) — hub doküman — ve
[`docs/reference/platform/`](docs/reference/platform/) — tam mimari.

Bu depo şu an yalnızca **backend**'i içerir (Flutter mobil ayrı bir adım).

## Dizin Yapısı

```
backend/     Tek Go modülü: pay-auth/chain-gateway/cheque/tx/anchor/scheduler
contracts/   pay-escrow Soroban kontratı (Rust)
deploy/      docker-compose, Dockerfile, APISIX, migrations, env örneği
scripts/     setup-secrets / dev-up / smoke / e2e
docs/        mimari referans dokümanları
```

## Hızlı Başlangıç

```sh
bash scripts/setup-secrets.sh
# deploy/.env dosyasını doldur: SEP10_SIGNING_SEED, KEEPER_SECRET_SEED,
# PAY_ESCROW_CONTRACT_ID (bkz. contracts/soroban/pay-escrow/README.md),
# ASSET_SAC_CONTRACT_ID, ASSET_ISSUER

bash scripts/dev-up.sh
bash scripts/smoke.sh
```

## Test

```sh
cd backend && go test ./...
cd contracts/soroban/pay-escrow && cargo test
```

## Kapsam sınırlamaları

Bilinçli olarak dar bırakılan yerler için [`SERVICE.md`](SERVICE.md)'ye
bakın.
