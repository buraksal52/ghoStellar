#!/usr/bin/env bash
# scripts/dev-up.sh — brings up the microservice profile for local dev.
# No `make` (Windows has none by default, and the plan deliberately skips
# tools/render for a 5-service MVP — see the plan's "Render tool'u almama
# kararı"); this script is the entrypoint instead.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -f deploy/secrets/jwt_private.pem ]; then
	echo "No dev secrets yet — running scripts/setup-secrets.sh first."
	bash scripts/setup-secrets.sh
fi

if [ ! -f deploy/env/.env ]; then
	echo "deploy/env/.env is missing. Copy deploy/env/example.env and fill it in first." >&2
	exit 1
fi

cd deploy
docker compose --env-file env/.env up --build -d
echo
echo "Waiting for services to report healthy..."
docker compose --env-file env/.env ps
echo
echo "Edge: http://localhost:9080   Postgres: localhost:${POSTGRES_HOST_PORT:-5434}"
echo "Run scripts/smoke.sh to verify the edge, or 'docker compose logs -f <service>' to watch one."
