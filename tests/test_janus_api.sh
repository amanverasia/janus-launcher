#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/janus_api.sh
source "$ROOT/lib/janus_api.sh"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

for case in \
  'https://janus.test|https://janus.test/v1' \
  'https://janus.test/|https://janus.test/v1' \
  'https://janus.test/v1|https://janus.test/v1' \
  'https://janus.test/v1/|https://janus.test/v1'
do
  IFS='|' read -r input expected <<<"$case"
  assert_eq "$(janus_api_root "$input")" "$expected" "api root for $input"
done
pass "API root normalization"

! janus_catalog_validate_json 'not-json' || fail "plain text should be invalid"
! janus_catalog_validate_json '{}' || fail "missing data should be invalid"
! janus_catalog_validate_json '{"data":{}}' || fail "non-array data should be invalid"
! janus_catalog_validate_json '{"data":[{"id":7}]}' || fail "non-string ID should be invalid"
! janus_catalog_validate_json '{"data":[{"id":""}]}' || fail "empty ID should be invalid"
janus_catalog_validate_json '{"data":[{"id":"provider/model"}]}' \
  || fail "string model ID should be valid"
pass "catalog schema validation"

ids="$(janus_extract_model_ids "$(<"$ROOT/tests/fixtures/models_openai.json")")"
printf '%s\n' "$ids" | grep -qx 'deepseek/deepseek-v4-pro' || fail "openai extract"
pass "openai extract"

ids="$(janus_extract_model_ids "$(<"$ROOT/tests/fixtures/models_anthropic.json")")"
printf '%s\n' "$ids" | grep -qx 'claude-sonnet-4' || fail "anthropic extract"
pass "anthropic extract"

! janus_extract_model_ids '{"data":{}}' >/dev/null \
  || fail "extract should reject malformed catalog"
pass "extract rejects malformed catalog"

janus_catalog_contains "$(<"$ROOT/tests/fixtures/models_openai.json")" 'combo-fast' \
  || fail "contains combo"
! janus_catalog_contains "$(<"$ROOT/tests/fixtures/models_openai.json")" 'combo' \
  || fail "partial ID should not match"
! janus_catalog_contains "$(<"$ROOT/tests/fixtures/models_openai.json")" 'missing/x' \
  || fail "missing should fail"
! janus_catalog_contains '{"data":{}}' 'combo-fast' \
  || fail "contains should reject malformed catalog"
pass "catalog contains exact ID"

ids="$(janus_extract_model_ids "$(<"$ROOT/tests/fixtures/models_empty.json")")"
[[ -z "$ids" ]] || fail "empty catalog extract"
pass "empty catalog extract"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fake-bin"
cat > "$TMP/fake-bin/curl" <<'SH'
#!/bin/bash
{
  printf '%s\n' '--- invocation ---'
  printf '%s\n' "$@"
} >> "$CURL_LOG"

url="${!#}"
case "$url" in
  */v1/health)
    [[ "${CURL_MODE:-success}" != health-failure ]] || exit 22
    exit 0
    ;;
  */v1/models)
    case "${CURL_MODE:-success}" in
      models-failure) exit 28 ;;
      malformed) printf '%s\n' 'not-json' ;;
      empty) printf '%s\n' '{"object":"list","data":[]}' ;;
      newline-id) printf '%s\n' '{"object":"list","data":[{"id":"\n"}]}' ;;
      success) printf '%s\n' '{"object":"list","data":[{"id":"provider/model"}]}' ;;
    esac
    ;;
  *) exit 7 ;;
esac
SH
chmod +x "$TMP/fake-bin/curl"
REAL_PATH="$PATH"
TEST_PATH="$TMP/fake-bin:$REAL_PATH"
export CURL_LOG="$TMP/curl.log"

run_validation() {
  local mode="$1"
  set +e
  validation_output="$(CURL_MODE="$mode" PATH="$TEST_PATH" janus_validate_service \
    'https://janus.test/v1/' 'test-key' 2>"$TMP/validation.err")"
  validation_rc=$?
  set -e
}

run_validation health-failure
assert_eq "$validation_rc" '1' "health failure status"

run_validation models-failure
assert_eq "$validation_rc" '2' "catalog transport failure status"

run_validation malformed
assert_eq "$validation_rc" '3' "malformed catalog status"

run_validation empty
assert_eq "$validation_rc" '4' "empty catalog status"

run_validation newline-id
assert_eq "$validation_rc" '0' "nonempty catalog with newline ID status"
assert_eq "$validation_output" '{"object":"list","data":[{"id":"\n"}]}' \
  "nonempty catalog with newline ID output"

: > "$CURL_LOG"
run_validation success
assert_eq "$validation_rc" '0' "successful validation status"
assert_eq "$validation_output" '{"object":"list","data":[{"id":"provider/model"}]}' \
  "successful validation output"
assert_eq "$(grep -cFx 'https://janus.test/v1/models' "$CURL_LOG")" '1' \
  "models endpoint call count"
assert_eq "$(grep -cFx -- '--' "$CURL_LOG")" '2' "curl URL delimiter count"
mapfile -t curl_log_lines < "$CURL_LOG"
for i in "${!curl_log_lines[@]}"; do
  if [[ "${curl_log_lines[i]}" == -- ]]; then
    [[ "${curl_log_lines[i + 1]-}" == https://janus.test/v1/* ]] ||
      fail "curl -- must immediately precede URL"
  fi
done
grep -qFx 'Authorization: Bearer test-key' "$CURL_LOG" \
  || fail "catalog request authorization"
grep -qE '^janus-launcher/' "$CURL_LOG" || fail "Janus Launcher user agent"
! grep -E 'https?://.*test-key' "$CURL_LOG" >/dev/null \
  || fail "API key must not appear in URL"
pass "service validation status and request contract"

set +e
PATH="$TMP/fake-bin" janus_validate_service 'https://janus.test' 'test-key' \
  >/dev/null 2>"$TMP/missing.err"
missing_rc=$?
set -e
assert_eq "$missing_rc" '127' "missing jq status"
pass "missing dependency status"

printf 'All janus_api unit tests passed.\n'
