#!/usr/bin/env bash
# End-to-end check of the CLI against the Rust Pact Broker (pact_broker-rs),
# run with its filesystem blob store so we can see where the content lands.
#
#   PACT_BROKER_RS_DIR=../../you54f/pact_broker-rs tests/e2e/rust-broker.sh
#
# PACT_BROKER_RS_BIN points at a built broker instead. Needs curl and jq.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$(pwd)

if [[ -z "${PACT_BROKER_RS_BIN:-}" ]]; then
  BROKER_DIR=${PACT_BROKER_RS_DIR:-../../you54f/pact_broker-rs}
  (cd "$BROKER_DIR" && cargo build -q --bin pact_broker)
  PACT_BROKER_RS_BIN="$(cd "$BROKER_DIR" && pwd)/target/debug/pact_broker"
fi
cargo build -q --bin pact-broker-cli
CLI="$ROOT/target/debug/pact-broker-cli"

WORK=$(mktemp -d)
PORT=${PORT:-$((20000 + RANDOM % 10000))}
BROKER="http://localhost:$PORT"
BLOBS="$WORK/blobs"
BROKER_PID=
cleanup() {
  [[ -n "$BROKER_PID" ]] && kill "$BROKER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- broker log ---" >&2
  tail -50 "$WORK/broker.log" >&2
  exit 1
}
step() { echo "==> $*"; }

step "Starting the Rust broker on $BROKER"
(
  cd "$WORK"
  exec env -u PACT_BROKER_TOKEN \
    PACT_BROKER_DATABASE_URL="sqlite://$WORK/broker.sqlite" \
    PACT_BROKER_PORT="$PORT" \
    PACT_BROKER_BASE_URL="$BROKER" \
    PACT_BROKER_BLOB_STORE=filesystem \
    PACT_BROKER_BLOB_STORE_PATH="$BLOBS" \
    "$PACT_BROKER_RS_BIN"
) >"$WORK/broker.log" 2>&1 &
BROKER_PID=$!
for _ in $(seq 1 100); do
  curl -sf "$BROKER/diagnostic/status/heartbeat" >/dev/null && break
  kill -0 "$BROKER_PID" 2>/dev/null || fail "the broker exited"
  sleep 0.1
done
curl -sf "$BROKER/diagnostic/status/heartbeat" >/dev/null || fail "the broker did not start"

export PACT_BROKER_BASE_URL="$BROKER"
unset PACT_BROKER_TOKEN PACT_BROKER_USERNAME PACT_BROKER_PASSWORD

blob_count() { find "$BLOBS" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

step "Publishing pacts/ as 1.0.0 on main"
"$CLI" publish pacts --consumer-app-version 1.0.0 --branch main || fail "publish"
[[ $(blob_count) == 2 ]] || fail "expected 2 blobs, found $(blob_count)"

step "Republishing the same content as 1.0.1 stores no new blob"
"$CLI" publish pacts --consumer-app-version 1.0.1 --branch main || fail "republish"
[[ $(blob_count) == 2 ]] || fail "expected 2 blobs after republishing, found $(blob_count)"

step "Each stored blob is the published document, named by its SHA-256"
for blob in $(find "$BLOBS" -type f ! -name '.*'); do
  [[ $(shasum -a 256 "$blob" | cut -d' ' -f1) == $(basename "$blob") ]] \
    || fail "$blob does not match its hash"
done

# The broker gives back the stored blob with an `_id` added to each
# interaction, as Ruby does. (The blob is what the CLI sent, which is not
# byte for byte the file: the CLI drops an empty `matchingRules.header`.)
step "Reading the pacts back gives the stored blobs"
for file in pacts/*.json; do
  consumer=$(jq -r .consumer.name "$file")
  provider=$(jq -r .provider.name "$file")
  got=$(curl -sf -H 'Accept: application/hal+json' \
    "$BROKER/pacts/provider/$provider/consumer/$consumer/latest") \
    || fail "GET latest $consumer -> $provider"
  stored=$(find "$BLOBS" -type f ! -name '.*' -exec cat {} + \
    | jq -cS --arg c "$consumer" 'select(.consumer.name == $c) | .interactions')
  [[ $(jq -cS '.interactions | map(del(._id))' <<<"$got") == "$stored" ]] \
    || fail "the interactions read back for $consumer differ from the blob"
  [[ $(jq -c '.interactions[0].description' <<<"$got") == $(jq -c '.interactions[0].description' "$file") ]] \
    || fail "the pact read back for $consumer is not $file"
done
"$CLI" get-pacts --provider GettingStartedOrderApi --output json >"$WORK/pacts.json" \
  || fail "get-pacts"
jq -e 'length > 0' "$WORK/pacts.json" >/dev/null || fail "get-pacts returned nothing"
"$CLI" list-latest-pact-versions >/dev/null || fail "list-latest-pact-versions"

step "can-i-deploy is refused before verification"
if "$CLI" can-i-deploy --pacticipant GettingStartedOrderWeb --version 1.0.1; then
  fail "can-i-deploy passed with no verification"
fi

step "Publishing a successful verification of 1.0.1"
pact=$(curl -sf -H 'Accept: application/hal+json' \
  "$BROKER/pacts/provider/GettingStartedOrderApi/consumer/GettingStartedOrderWeb/version/1.0.1")
verifications=$(jq -r '._links."pb:publish-verification-results".href' <<<"$pact")
curl -sf -X POST -H 'Content-Type: application/json' "$verifications" \
  -d '{"success":true,"providerApplicationVersion":"2.0.0","providerVersionBranch":"main"}' \
  >/dev/null || fail "publishing the verification"

step "can-i-deploy passes after verification"
"$CLI" can-i-deploy --pacticipant GettingStartedOrderWeb --version 1.0.1 \
  || fail "can-i-deploy after verification"

step "can-i-deploy links to the verification it used"
link=$("$CLI" can-i-deploy --pacticipant GettingStartedOrderWeb --version 1.0.1 --output json \
  | jq -r '.matrix[0].verificationResult._links.self.href')
[[ $link == */pact-version/*/metadata/*/verification-results/* ]] \
  || fail "unexpected verification link $link"
curl -sf -H 'Accept: application/hal+json' "$link" | jq -e '.success == true' >/dev/null \
  || fail "the verification link $link does not resolve"

step "Recording a deployment and checking against the environment"
"$CLI" create-environment --name e2e-production --production >/dev/null || fail "create-environment"
"$CLI" record-deployment --pacticipant GettingStartedOrderApi --version 2.0.0 \
  --environment e2e-production || fail "record-deployment"
"$CLI" can-i-deploy --pacticipant GettingStartedOrderWeb --version 1.0.1 \
  --to-environment e2e-production || fail "can-i-deploy --to-environment"

step "Merging a pact (PATCH) reads the stored blob"
"$CLI" publish pacts/GettingStartedOrderWeb-GettingStartedOrderApi.json \
  --consumer-app-version 1.0.1 --branch main --merge || fail "publish --merge"

echo "PASS: the CLI works against the Rust broker ($(blob_count) blobs stored)"
