#!/bin/sh
set -eu

: "${DATABASE_URL:?DATABASE_URL must point to the Railway PostgreSQL service}"
exec /app/migrate -path=/app/migrations -database="$DATABASE_URL" up
