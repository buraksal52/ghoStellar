#!/usr/bin/env bash
# scripts/e2e.sh — testnet end-to-end happy path (plan's Doğrulama
# scenario 1): two accounts, friendbot, trustline, fund the sender via the
# TR Mock Anchor's SEP-6 deposit, write a cheque, lock, claim, assert
# Claimed. See docs/reference/platform/anchor-entegrasyonu.md for the
# SEP-6 flow this script drives.
#
# Scenarios 2-4 (force_collect, timeout refund, pool lock) are exercised by
# contracts/soroban/pay-escrow/src/test.rs on the contract side already;
# scripting them end-to-end through the running services as well is not
# done yet — SERVICE.md tracks this as open work. This script is the
# reference shape for adding them: same account setup, different XDR
# endpoint, different assertion.
set -euo pipefail

EDGE="${1:-http://localhost:9080}"
ASSET_CODE="${ASSET_CODE:-USDC}"

need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need stellar
need curl
need jq

echo "== Generating sender/receiver testnet accounts =="
stellar keys generate e2e_sender --network testnet --fund --overwrite
stellar keys generate e2e_receiver --network testnet --fund --overwrite
SENDER=$(stellar keys address e2e_sender)
RECEIVER=$(stellar keys address e2e_receiver)
echo "sender=$SENDER receiver=$RECEIVER"

login() {
	local name="$1" address="$2"
	local challenge_xdr
	challenge_xdr=$(curl -s "$EDGE/auth/challenge?account=$address" | jq -r '.data.transaction')
	local signed_xdr
	signed_xdr=$(stellar tx sign --sign-with-key "$name" --network testnet <<<"$challenge_xdr")
	curl -s -X POST "$EDGE/auth/token" -H 'Content-Type: application/json' \
		-d "$(jq -n --arg tx "$signed_xdr" '{transaction:$tx}')" | jq -r '.data.accessToken'
}

echo "== SEP-10 login for both accounts =="
SENDER_TOKEN=$(login e2e_sender "$SENDER")
RECEIVER_TOKEN=$(login e2e_receiver "$RECEIVER")

echo "== Establishing trustline for both accounts =="
for pair in "e2e_sender:$SENDER_TOKEN" "e2e_receiver:$RECEIVER_TOKEN"; do
	name="${pair%%:*}"; token="${pair##*:}"
	trust_xdr=$(curl -s "$EDGE/anchors/default/trustline-xdr" -H "Authorization: Bearer $token" | jq -r '.data.trustlineXdr')
	signed=$(stellar tx sign --sign-with-key "$name" --network testnet <<<"$trust_xdr")
	curl -s -X POST "$EDGE/tx/submit" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
		-d "$(jq -n --arg xdr "$signed" --arg key "trustline-$name" '{idempotencyKey:$key,purpose:"auth.trustline",kind:"classic",xdr:$xdr}')" >/dev/null
done
echo "== Funding sender via the TR Mock Anchor (SEP-6 deposit) =="
anchor_login() {
	# The anchor's own SEP-10 challenge is issued for whichever account our
	# bearer JWT (X-Internal caller identity) resolves to server-side — see
	# anchor.Handler.Challenge — so this only needs the signing key alias.
	local name="$1"
	local challenge_xdr signed_xdr
	challenge_xdr=$(curl -s "$EDGE/anchors/default/auth/challenge" -H "Authorization: Bearer ${SENDER_TOKEN}" | jq -r '.data.transaction')
	signed_xdr=$(stellar tx sign --sign-with-key "$name" --network testnet <<<"$challenge_xdr")
	curl -s -X POST "$EDGE/anchors/default/auth/token" -H "Authorization: Bearer ${SENDER_TOKEN}" -H 'Content-Type: application/json' \
		-d "$(jq -n --arg tx "$signed_xdr" '{transaction:$tx}')" | jq -r '.data.token'
}
ANCHOR_TOKEN=$(anchor_login e2e_sender)

deposit_resp=$(curl -s -G "$EDGE/anchors/default/sep6/deposit" \
	-H "Authorization: Bearer ${SENDER_TOKEN}" -H "X-Anchor-Token: ${ANCHOR_TOKEN}" \
	--data-urlencode "asset_code=${ASSET_CODE}" --data-urlencode "amount=1000")
DEPOSIT_ID=$(echo "$deposit_resp" | jq -r '.data.id')
echo "deposit id=$DEPOSIT_ID, how=$(echo "$deposit_resp" | jq -r '.data.how')"

echo "== Simulating the bank transfer (mock-anchor-only endpoint) =="
curl -s -X POST "$EDGE/anchors/default/sep6/tx/${DEPOSIT_ID}/simulate-bank-transfer" \
	-H "Authorization: Bearer ${SENDER_TOKEN}" -H "X-Anchor-Token: ${ANCHOR_TOKEN}" -H 'Content-Type: application/json' \
	-d '{"amount":"1000"}' >/dev/null

echo "== Polling for deposit completion =="
for _ in $(seq 1 20); do
	status=$(curl -s -G "$EDGE/anchors/default/sep6/transaction" -H "Authorization: Bearer ${SENDER_TOKEN}" -H "X-Anchor-Token: ${ANCHOR_TOKEN}" \
		--data-urlencode "id=${DEPOSIT_ID}" | jq -r '.data.transaction.status')
	echo "  status=$status"
	[ "$status" = "completed" ] && break
	sleep 3
done
curl -s -X POST "$EDGE/anchors/default/transactions/${DEPOSIT_ID}/report" -H "Authorization: Bearer ${SENDER_TOKEN}" -H 'Content-Type: application/json' \
	-d "$(jq -n --arg amt "1000" '{kind:"deposit",state:"completed",amount:$amt,decimals:7}')" >/dev/null

echo "== Writing a cheque: sender -> receiver, 10 $ASSET_CODE =="
create_resp=$(curl -s -X POST "$EDGE/cheques" -H "Authorization: Bearer $SENDER_TOKEN" -H 'Content-Type: application/json' \
	-d "$(jq -n --arg r "$RECEIVER" '{receiver:$r,amount:"10"}')")
CHEQUE_ID=$(echo "$create_resp" | jq -r '.data.chequeId')
LOCK_XDR=$(echo "$create_resp" | jq -r '.data.lockXdr')
echo "chequeId=$CHEQUE_ID"

echo "== Signing + submitting lock =="
SIGNED_LOCK=$(stellar tx sign --sign-with-key e2e_sender --network testnet <<<"$LOCK_XDR")
curl -s -X POST "$EDGE/tx/submit" -H "Authorization: Bearer $SENDER_TOKEN" -H 'Content-Type: application/json' \
	-d "$(jq -n --arg xdr "$SIGNED_LOCK" --arg key "lock-$CHEQUE_ID" '{idempotencyKey:$key,purpose:"cheque.lock",kind:"soroban",xdr:$xdr}')" | jq .
curl -s -X POST "$EDGE/cheques/$CHEQUE_ID/confirm-lock" -H "Authorization: Bearer $SENDER_TOKEN" -H 'Content-Type: application/json' -d '{}' >/dev/null

echo "== Receiver claims =="
claim_xdr=$(curl -s -X POST "$EDGE/cheques/$CHEQUE_ID/claim-xdr" -H "Authorization: Bearer $RECEIVER_TOKEN" | jq -r '.data.claimXdr')
signed_claim=$(stellar tx sign --sign-with-key e2e_receiver --network testnet <<<"$claim_xdr")
curl -s -X POST "$EDGE/tx/submit" -H "Authorization: Bearer $RECEIVER_TOKEN" -H 'Content-Type: application/json' \
	-d "$(jq -n --arg xdr "$signed_claim" --arg key "claim-$CHEQUE_ID" '{idempotencyKey:$key,purpose:"cheque.claim",kind:"soroban",xdr:$xdr}')" | jq .
curl -s -X POST "$EDGE/cheques/$CHEQUE_ID/confirm-claim" -H "Authorization: Bearer $RECEIVER_TOKEN" -H 'Content-Type: application/json' -d '{}' >/dev/null

echo "== Verifying via Forced Sync =="
state=$(curl -s "$EDGE/sync" -H "Authorization: Bearer $RECEIVER_TOKEN" | jq -r --arg id "$CHEQUE_ID" '.data.cheques[] | select(.id==$id) | .state')
if [ "$state" = "TALEP_EDILDI" ] || [ "$state" = "ONAYLANDI" ] || [ "$state" = "KAPANDI" ]; then
	echo "PASS: cheque $CHEQUE_ID reached $state"
else
	echo "FAIL: expected TALEP_EDILDI/ONAYLANDI/KAPANDI, got '$state'" >&2
	exit 1
fi
