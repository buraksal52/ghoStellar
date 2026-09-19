#!/usr/bin/env bash
# scripts/smoke.sh [EDGE_URL] — verifies the APISIX edge routes correctly,
# without needing a funded testnet account. Modeled on Agent-Tale's
# deployment/verify/smoke.sh (see the plan's Doğrulama section): each
# service's own /health is checked directly by Docker's healthcheck, not
# through the edge — this script's job is the EDGE's behavior.
set -euo pipefail

EDGE="${1:-http://localhost:9080}"
fail=0

check() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$actual" = "$expected" ]; then
		echo "OK   $desc ($actual)"
	else
		echo "FAIL $desc (expected $expected, got $actual)"
		fail=1
	fi
}

echo "Smoke testing edge at $EDGE"
echo

# /internal/* must never be reachable from outside the cluster.
status=$(curl -s -o /dev/null -w "%{http_code}" "$EDGE/internal/anything")
check "/internal/* is denied" 403 "$status"

# A syntactically invalid account still proves routing + service wiring:
# apisix -> pay-auth-service -> our own validation (400), not a gateway
# timeout or 502 (which would mean the route or upstream is broken).
status=$(curl -s -o /dev/null -w "%{http_code}" "$EDGE/auth/challenge?account=not-a-valid-address")
check "/auth/challenge routes to pay-auth-service" 400 "$status"

# /sync requires a bearer token — 401, not 404/502, proves pay-cheque-
# service is reachable through the edge.
status=$(curl -s -o /dev/null -w "%{http_code}" "$EDGE/sync")
check "/sync routes to pay-cheque-service" 401 "$status"

# POST /cheques (no trailing segment) regression check (SERVICE.md #19a):
# APISIX's /cheques/* uri only matched a sub-segment, so this used to 404
# at the edge while the service itself (behind :8083 directly) correctly
# answered 401. Expect 401 here, never 404.
status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$EDGE/cheques")
check "POST /cheques (no segment) routes to pay-cheque-service" 401 "$status"

# GET /anchors (no trailing segment) has the identical gap on the anchor
# route's uris.
status=$(curl -s -o /dev/null -w "%{http_code}" "$EDGE/anchors")
check "GET /anchors (no segment) routes to pay-anchor-service" 401 "$status"

# SERVICE.md #16: a client-supplied X-Internal-Api-Key must never grant
# anything from outside the cluster — the edge strips it (proxy-rewrite in
# apisix.yaml) before the upstream ever sees it. This is defense in depth
# on top of internal-deny (which already blocks /internal/* outright): the
# check here is that forging the header on an ordinary route changes
# nothing — /sync still answers plain 401, not some different behavior.
status=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Internal-Api-Key: forged" "$EDGE/sync")
check "forged X-Internal-Api-Key on /sync has no effect (still 401)" 401 "$status"

# X-Request-Id must be present on every response (httpx.WithRequestID).
headers=$(curl -s -D - -o /dev/null -H "Origin: http://localhost:3000" "$EDGE/auth/challenge?account=not-a-valid-address")
if echo "$headers" | grep -qi "^x-request-id:"; then
	echo "OK   X-Request-Id header present"
else
	echo "FAIL X-Request-Id header missing"
	fail=1
fi

# Exactly one Access-Control-Allow-Origin header — a doubled CORS header
# (once from apisix, once from an upstream) is a real, easy-to-reintroduce
# bug this check exists to catch.
cors_count=$(echo "$headers" | grep -ci "^access-control-allow-origin:" || true)
check "exactly one Access-Control-Allow-Origin header" 1 "$cors_count"

echo
if [ "$fail" -eq 0 ]; then
	echo "All smoke checks passed."
else
	echo "Some smoke checks failed." >&2
	exit 1
fi
