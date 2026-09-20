# Railway deployment

The repository root contains a Railway Dockerfile build for the Go monolith
(`backend/cmd/monolith`). The root `railway.json` selects that Dockerfile,
runs the SQL migrations before each deployment, and checks `/health`.

## Railway service setup

Create a Railway service from this repository with the repository root as its
source directory. Do not set the service root directory to `/backend`; the
Docker build needs both `backend/` and `deploy/migrations/`.

Add a Railway PostgreSQL service and set `DATABASE_URL` on the app service to
the Postgres service's private `DATABASE_URL` reference. The pre-deploy step
runs the migrations from `deploy/migrations/` against that database.

Set these application variables on the service:

| Variable | Purpose |
| --- | --- |
| `SEP10_SIGNING_SEED` | Stellar account seed used by SEP-10 auth |
| `KEEPER_SECRET_SEED` | Testnet scheduler/keeper account seed |
| `PAY_ESCROW_CONTRACT_ID` | Deployed escrow contract ID |
| `ASSET_SAC_CONTRACT_ID` | Stellar asset contract ID |
| `JWT_PRIVATE_KEY` | PEM-encoded RSA private key |
| `JWT_PUBLIC_KEY` | Matching PEM-encoded RSA public key |
| `DATABASE_URL` | Railway PostgreSQL connection URL |

The service listens on `0.0.0.0:$PORT` (defaulting to port 8080 locally).
After the first healthy deployment, generate a public domain from the Railway
service's Networking settings. The health endpoint is `/health`.

This deployment targets the existing testnet configuration. Set
`NETWORK_PASSPHRASE`, `HORIZON_URL`, `SOROBAN_RPC_URL`, contract IDs, and
Anchor settings explicitly when targeting another network or Anchor.

The Flutter client learns `NETWORK_PASSPHRASE` from `/sync` at runtime
(SERVICE.md #20) — no client rebuild needed for this variable alone. It
still needs a matching build for anything build-time: `GATEWAY_BASE_URL`
(this service's public domain) and, if the asset differs from the default,
`PAY_ASSET_CODE`/`PAY_ASSET_ISSUER`.
