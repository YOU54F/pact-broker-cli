#!/usr/bin/env bash
# End-to-end check of the CLI against the Rust Pact Broker (pact_broker-rs),
# run with its filesystem blob store so we can see where the content lands.
#
#   PACT_BROKER_RS_DIR=../../you54f/pact_broker-rs tests/e2e/rust-broker.sh
#
# PACT_BROKER_RS_BIN points at a built broker instead. Needs curl, jq and
# python3 (for the stub comparator).
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
COMPARATOR_PORT=$((PORT + 1))
COMPARATOR_PID=
cleanup() {
  [[ -n "$BROKER_PID" ]] && kill "$BROKER_PID" 2>/dev/null || true
  [[ -n "$COMPARATOR_PID" ]] && kill "$COMPARATOR_PID" 2>/dev/null || true
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

step "Starting a stub comparator on port $COMPARATOR_PORT"
python3 tests/e2e/stub-comparator.py "$COMPARATOR_PORT" >"$WORK/comparator.log" 2>&1 &
COMPARATOR_PID=$!
disown "$COMPARATOR_PID"

step "Starting the Rust broker on $BROKER"
(
  cd "$WORK"
  exec env -u PACT_BROKER_TOKEN \
    PACT_BROKER_DATABASE_URL="sqlite://$WORK/broker.sqlite" \
    PACT_BROKER_PORT="$PORT" \
    PACT_BROKER_BASE_URL="$BROKER" \
    PACT_BROKER_BLOB_STORE=filesystem \
    PACT_BROKER_BLOB_STORE_PATH="$BLOBS" \
    PACT_BROKER_ENABLE_BDCT=true \
    PACT_BROKER_BDCT_COMPARATOR_URL="http://127.0.0.1:$COMPARATOR_PORT" \
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

# The broker runs with its BDCT module on (PACT_BROKER_ENABLE_BDCT), which
# adds PactFlow's provider-contract resources over the generic core.
contract_url="$BROKER/contracts/provider/e2e-provider/version"
contract() { curl -sf -H 'Accept: application/hal+json' "$contract_url/$1"; }

step "Publishing an OpenAPI provider contract with no self-verification"
blobs_before=$(blob_count)
"$CLI" pactflow publish-provider-contract oas.yml --provider e2e-provider \
  --provider-app-version 3.0.0 --branch main --tag e2e \
  || fail "publish-provider-contract"
got=$(contract 3.0.0) || fail "GET the contract for 3.0.0"
[[ $(jq -r .content <<<"$got" | base64 -d) == $(cat oas.yml) ]] \
  || fail "the contract read back is not oas.yml"
jq -e '.contractType == "oas" and .contentType == "application/yaml"
  and (has("verificationResults") | not)' <<<"$got" >/dev/null \
  || fail "unexpected contract $got"
[[ $(blob_count) == $((blobs_before + 1)) ]] \
  || fail "expected one new blob for the contract, found $(blob_count)"

step "Publishing it again with self-verification results"
echo "all 12 operations verified" >"$WORK/results.txt"
"$CLI" pactflow publish-provider-contract oas.yml --provider e2e-provider \
  --provider-app-version 3.0.0 --branch main \
  --verification-success --verification-results "$WORK/results.txt" \
  --verification-results-content-type text/plain --verification-results-format text \
  --verifier e2e --verifier-version 1.2.3 \
  || fail "publish-provider-contract with results"
contract 3.0.0 | jq -e '.verificationResults | .success == true
  and .verifier == "e2e" and .verifierVersion == "1.2.3"
  and .contentType == "text/plain" and .format == "text"' >/dev/null \
  || fail "the self-verification results were not recorded"
[[ $(contract 3.0.0 | jq -r .verificationResults.content | base64 -d) == "all 12 operations verified" ]] \
  || fail "the self-verification results read back differ"

step "A different contract for the same version is refused"
sed 's/^\( *title:\).*/\1 changed/' oas.yml >"$WORK/changed.yml"
if "$CLI" pactflow publish-provider-contract "$WORK/changed.yml" --provider e2e-provider \
  --provider-app-version 3.0.0 --branch main; then
  fail "a conflicting contract was accepted"
fi

step "Self-verification results need content, as in PactFlow"
if "$CLI" pactflow publish-provider-contract oas.yml --provider e2e-provider \
  --provider-app-version 3.0.2 --branch main --verification-success --verifier e2e; then
  fail "self-verification results with no content were accepted"
fi

step "A failed self-verification on a new version is the latest contract"
"$CLI" pactflow publish-provider-contract "$WORK/changed.yml" --provider e2e-provider \
  --provider-app-version 3.0.1 --branch main --verification-exit-code 1 --verifier e2e \
  --verification-results "$WORK/results.txt" --verification-results-content-type text/plain \
  || fail "publish-provider-contract 3.0.1"
curl -sf -H 'Accept: application/hal+json' "$BROKER/contracts/provider/e2e-provider/latest" \
  | jq -e '(._links.self.href | endswith("/version/3.0.1"))
    and .verificationResults.success == false' >/dev/null \
  || fail "the latest contract is not 3.0.1's"

# With a comparator configured, the broker compares each consumer pact with
# the provider's contracts in the background, and can-i-deploy uses the
# verdict. The stub passes a pact when oas.yml has every path it requests.
bdct_url="$BROKER/contracts/bi-directional/provider/e2e-provider/version"
consumer_pact() {
  jq --arg path "$1" '.consumer.name = "e2e-consumer" | .provider.name = "e2e-provider"
    | .interactions |= map(.request.path = $path)' \
    pacts/GettingStartedOrderWeb-GettingStartedOrderApi.json >"$WORK/e2e-consumer.json"
}
compared() {
  local view
  for _ in $(seq 1 100); do
    view=$(curl -sf -H 'Accept: application/hal+json' \
      "$bdct_url/$1/consumer/e2e-consumer/version/$2/cross-contract-verification-results") \
      && jq -e '._embedded.crossContractVerificationResults' <<<"$view" >/dev/null \
      && { echo "$view"; return; }
    sleep 0.1
  done
  fail "no comparison of e2e-consumer $2 with e2e-provider $1"
}

step "Publishing a self-verified contract as 3.0.3"
"$CLI" pactflow publish-provider-contract oas.yml --provider e2e-provider \
  --provider-app-version 3.0.3 --branch main --verification-success --verifier e2e \
  --verification-results "$WORK/results.txt" --verification-results-content-type text/plain \
  || fail "publish-provider-contract 3.0.3"

step "A consumer pact within the contract is compared, and passes"
consumer_pact /contracts/publish
"$CLI" publish "$WORK/e2e-consumer.json" --consumer-app-version 1.0.0 --branch main \
  || fail "publishing e2e-consumer 1.0.0"
view=$(compared 3.0.3 1.0.0)
jq -e '._embedded.crossContractVerificationResults
  | .success == true and .verifier == "e2e-stub" and .results == {errors: [], warnings: []}' <<<"$view" >/dev/null \
  || fail "the comparison of 1.0.0 did not pass: $(jq -c ._embedded.crossContractVerificationResults <<<"$view")"
"$CLI" can-i-deploy --pacticipant e2e-consumer --version 1.0.0 \
  --pacticipant e2e-provider --version 3.0.3 \
  || fail "can-i-deploy with a passing comparison"

step "A consumer pact outside the contract is compared, and fails"
consumer_pact /orders
"$CLI" publish "$WORK/e2e-consumer.json" --consumer-app-version 1.0.1 --branch main \
  || fail "publishing e2e-consumer 1.0.1"
view=$(compared 3.0.3 1.0.1)
jq -e '._embedded.crossContractVerificationResults | .success == false
  and (.results.errors | length > 0)' <<<"$view" >/dev/null \
  || fail "the comparison of 1.0.1 did not fail: $(jq -c ._embedded.crossContractVerificationResults <<<"$view")"
if "$CLI" can-i-deploy --pacticipant e2e-consumer --version 1.0.1 \
  --pacticipant e2e-provider --version 3.0.3; then
  fail "can-i-deploy passed with a failed comparison"
fi

echo "PASS: the CLI works against the Rust broker ($(blob_count) blobs stored)"
