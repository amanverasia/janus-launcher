#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# The runtime module is intentionally sourced before it exists during RED.
source "$ROOT/lib/janus_api.sh"
source "$ROOT/lib/janus_runtime.sh"

janus_is_top_level_passthrough --help || fail "--help passthrough"
janus_is_top_level_passthrough help --verbose || fail "help passthrough"
janus_is_top_level_passthrough -V || fail "-V passthrough"
! janus_is_top_level_passthrough exec --help || fail "nested help bypassed setup"
! janus_is_top_level_passthrough -p 'explain -h' || fail "prompt text bypassed setup"
pass "first-position passthrough detection"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/first" "$TMP/second"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/first/claude-janus"
chmod +x "$TMP/first/claude-janus"
ln -s claude-janus "$TMP/first/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/second/claude"
chmod +x "$TMP/second/claude"
resolved="$(PATH="$TMP/first:$TMP/second:/usr/bin:/bin" janus_resolve_client_executable claude "$TMP/first/claude-janus")" \
  || fail "resolve child after wrapper"
assert_eq "$resolved" "$TMP/second/claude" "resolved executable"
set +e
PATH="$TMP/first:/usr/bin:/bin" janus_resolve_client_executable claude "$TMP/first/claude-janus" >"$TMP/missing.out"
rc=$?
set -e
[[ $rc -eq 127 && ! -s "$TMP/missing.out" ]] || fail "wrapper-only resolution returns 127"
pass "client executable resolution skips wrapper"

calls_file="$TMP/validation.calls"
: > "$calls_file"
janus_config_init_paths() { JANUS_ROUTER_CONFIG="$TMP/router.conf"; }
janus_config_load_router() {
  assert_eq "$1" "$TMP/router.conf" "router path"
  JANUS_BASE_URL='https://janus.test/v1/'
  JANUS_API_KEY='test-key'
}
janus_config_is_placeholder() { return 1; }
janus_config_run_first_setup() { fail "unexpected setup"; }
janus_validate_service() {
  printf 'called\n' >> "$calls_file"
  assert_eq "$1" 'https://janus.test' "validated normalized URL"
  assert_eq "$2" 'test-key' "validated API key"
  printf '{"data":[{"id":"provider/model"}]}\n'
}
JANUS_BASE_URL= JANUS_API_KEY= JANUS_CATALOG_JSON=
janus_load_validated_service || fail "load validated service"
assert_eq "$(wc -l < "$calls_file")" 1 "validation call count"
assert_eq "$JANUS_BASE_URL" 'https://janus.test' "caller base URL"
assert_eq "$JANUS_API_KEY" 'test-key' "caller API key"
assert_eq "$JANUS_CATALOG_JSON" '{"data":[{"id":"provider/model"}]}' "caller catalog"
pass "validated service remains in caller shell"

janus_require_command definitely-not-a-real-command 'Example dependency' 2>"$TMP/require.err" && \
  fail "missing dependency accepted"
grep -Fq 'Example dependency' "$TMP/require.err" || fail "dependency label omitted"
pass "dependency diagnostics"

printf 'All janus_runtime unit tests passed.\n'
