#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$ROOT/bin/janus-control"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }

mkdir -p "$TMP/bin" "$TMP/config"
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"
printf '%s\n' "$url" >> "$JANUS_TEST_CURL_LOG"
case "$url" in
  */v1/health)
    [[ "${JANUS_TEST_CURL_MODE:-success}" != health-failure ]] || exit 22
    exit 0
    ;;
  */v1/models)
    case "${JANUS_TEST_CURL_MODE:-success}" in
      catalog-failure) exit 22 ;;
      malformed) printf '%s\n' 'not-json' ;;
      empty) printf '%s\n' '{"data":[]}' ;;
      *) printf '%s\n' '{"data":[{"id":"deepseek/deepseek-v4-pro"},{"id":"kimi-api/kimi-k3"}]}' ;;
    esac
    ;;
  *) exit 7 ;;
esac
SH
chmod +x "$TMP/bin/curl"

printf 'JANUS_BASE_URL=https://janus.test/v1/\nJANUS_API_KEY=test-control-secret\n' \
  > "$TMP/config/router.conf"
BASE_ENV=(PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home"
  JANUS_LAUNCHER_CONFIG_DIR="$TMP/config" JANUS_TEST_CURL_LOG="$TMP/curl.log")
run_control() { env "${BASE_ENV[@]}" "$CONTROL" "$@"; }

models="$(run_control models)"
assert_eq "$models" $'deepseek/deepseek-v4-pro\nkimi-api/kimi-k3' 'models outputs exact catalog IDs'
assert_eq "$(<"$TMP/curl.log")" $'https://janus.test/v1/health\nhttps://janus.test/v1/models' \
  'models endpoint order'
pass 'models validates Janus then prints exact IDs'

: > "$TMP/curl.log"
status="$(run_control status)"
assert_eq "$status" $'Janus endpoint: https://janus.test\nService health: healthy\nModels: 2 available' 'status output'
[[ "$status" != *'test-control-secret'* ]] || fail 'status leaked API key'
pass 'status reports endpoint health and catalog size'

: > "$TMP/curl.log"
doctor="$(run_control doctor)"
assert_contains "$doctor" 'PASS curl is available' 'doctor curl dependency'
assert_contains "$doctor" 'PASS jq is available' 'doctor jq dependency'
assert_contains "$doctor" 'PASS router configuration loaded' 'doctor configuration'
assert_contains "$doctor" 'PASS Janus health endpoint is reachable' 'doctor health'
assert_contains "$doctor" 'PASS authenticated catalog is valid (2 models)' 'doctor catalog'
! grep -F 'test-control-secret' <<<"$doctor" >/dev/null || fail 'doctor leaked API key'
! grep -q '/v1/responses' "$TMP/curl.log" || fail 'doctor must not invoke a generation endpoint'
pass 'doctor is read-only, validates catalog, and redacts credentials'

set +e
failed_doctor="$(env "${BASE_ENV[@]}" JANUS_TEST_CURL_MODE=health-failure "$CONTROL" doctor 2>&1)"
failed_rc=$?
set -e
[[ $failed_rc -eq 1 ]] || fail "health-failure doctor status: $failed_rc"
assert_contains "$failed_doctor" 'FAIL Janus health endpoint is unreachable.' 'doctor health failure'
! grep -F 'test-control-secret' <<<"$failed_doctor" >/dev/null || fail 'failed doctor leaked API key'
pass 'doctor gives actionable health failure without credential leakage'

placeholder="$TMP/placeholder"
mkdir -p "$placeholder"
set +e
missing_doctor="$(env PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/missing-home" JANUS_LAUNCHER_CONFIG_DIR="$placeholder" JANUS_TEST_CURL_LOG="$TMP/missing.log" "$CONTROL" doctor 2>&1)"
missing_rc=$?
set -e
[[ $missing_rc -eq 2 ]] || fail "missing configuration doctor status: $missing_rc"
assert_contains "$missing_doctor" 'FAIL router configuration is missing' 'doctor missing configuration'
[[ ! -s "$TMP/missing.log" ]] || fail 'doctor must not contact Janus with missing configuration'
pass 'doctor does not prompt, write, or connect when configuration is missing'

help_log="$TMP/help.log"
: > "$help_log"
help="$(env PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/help-home" JANUS_LAUNCHER_CONFIG_DIR="$TMP/not-a-directory" JANUS_TEST_CURL_LOG="$help_log" "$CONTROL" --help 2>&1)"
assert_contains "$help" 'Usage: janus-control' 'control help'
[[ ! -s "$help_log" && ! -e "$TMP/not-a-directory" ]] || fail 'control help touched config or network'
pass 'control help bypasses configuration and network'

printf 'All janus_control shell tests passed.\n'
