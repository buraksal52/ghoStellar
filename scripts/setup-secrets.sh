#!/usr/bin/env bash
# scripts/setup-secrets.sh
#
# Generates the PEM/key files docker-compose mounts into every service
# under deploy/secrets/. That directory is .gitignore'd; nothing here is a
# real secret once you're past testnet. See
# docs/reference/platform/architecture.md §10. Ported from De-Fi's
# dev/setup-secrets.sh, which this repo's plan calls out as the one script
# worth carrying over verbatim.
set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/secrets"
mkdir -p "$SECRETS_DIR"

if [ ! -f "$SECRETS_DIR/jwt_private.pem" ]; then
	echo "Generating dev JWT keypair (RS256) for pay-auth-service..."
	openssl genrsa -out "$SECRETS_DIR/jwt_private.pem" 2048
	openssl rsa -in "$SECRETS_DIR/jwt_private.pem" -pubout -out "$SECRETS_DIR/jwt_public.pem"
else
	echo "jwt_private.pem already exists, skipping."
fi

if [ ! -f "$SECRETS_DIR/../.env" ] && [ -f "$SECRETS_DIR/../example.env" ]; then
	echo "Copying deploy/example.env -> deploy/.env (fill in the blanks before 'docker compose up')."
	cp "$SECRETS_DIR/../example.env" "$SECRETS_DIR/../.env"
fi

INTERNAL_KEY_FILE="$SECRETS_DIR/../.env"
if [ -f "$INTERNAL_KEY_FILE" ] && ! grep -q "^INTERNAL_API_KEY=.\+" "$INTERNAL_KEY_FILE"; then
	KEY="$(openssl rand -hex 32)"
	if grep -q "^INTERNAL_API_KEY=" "$INTERNAL_KEY_FILE"; then
		sed -i.bak "s/^INTERNAL_API_KEY=.*/INTERNAL_API_KEY=${KEY}/" "$INTERNAL_KEY_FILE" && rm -f "$INTERNAL_KEY_FILE.bak"
	else
		echo "INTERNAL_API_KEY=${KEY}" >> "$INTERNAL_KEY_FILE"
	fi
	echo "Generated INTERNAL_API_KEY in deploy/.env."
fi

echo "Done."
echo "Still need, in deploy/.env: SEP10_SIGNING_SEED, KEEPER_SECRET_SEED,"
echo "PAY_ESCROW_CONTRACT_ID, ASSET_SAC_CONTRACT_ID, ASSET_ISSUER — see that"
echo "file's comments and contracts/soroban/pay-escrow/README.md."
