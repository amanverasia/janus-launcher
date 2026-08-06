#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$ROOT/bin/janus-control"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3 (unexpected: $2)"; }
mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  */v1/health) exit 0 ;;
  */v1/models)
    printf '%s\n' '{"data":[{"id":"provider/model-alpha"},{"id":"provider/model-beta"}]}'
    ;;
  *) exit 7 ;;
esac
SH
chmod +x "$TMP/bin/curl"

cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'CODEX_HOME=%s\n' "${CODEX_HOME-}" >> "$JANUS_TEST_CODEX_LOG"
printf 'ARGC=%d\n' "$#" >> "$JANUS_TEST_CODEX_LOG"
printf 'ARG=<%s>\n' "$@" >> "$JANUS_TEST_CODEX_LOG"
if [[ $# -eq 2 && "$1" == login && "$2" == status ]]; then
  case "${JANUS_TEST_LOGIN_MODE:-authenticated}" in
    authenticated) printf 'Logged in using ChatGPT\n'; exit 0 ;;
    signed-out) printf 'Not logged in\n' >&2; exit 1 ;;
    api-key) printf 'Logged in using an API key\n'; exit 0 ;;
    unknown) printf 'Unexpected login status response\n'; exit 0 ;;
  esac
fi
if [[ $# -eq 2 && "$1" == debug && "$2" == models ]]; then
  exit 0
fi
[[ $# -eq 3 && "$1" == debug && "$2" == models && "$3" == --bundled ]] || exit 64
cat <<'JSON'
{"models":[{"slug":"native-model","display_name":"Native model","description":"Native","priority":50,"visibility":"list","supported_in_api":true,"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"medium","description":"Medium"}],"context_window":200000,"max_context_window":200000,"auto_compact_token_limit":180000,"effective_context_window_percent":90,"input_modalities":["text","image"],"supports_search_tool":true,"supports_image_detail_original":true,"support_verbosity":true,"default_verbosity":"medium","additional_speed_tiers":[],"service_tiers":[],"availability_nux":null,"upgrade":null,"multi_agent_version":"v1"}]}
JSON
SH
chmod +x "$TMP/bin/codex"

SECRET='codex-app-secret $dollar `backtick`; semicolon'
new_case() {
  local name="$1"
  CASE_DIR="$TMP/$name"
  CASE_CONFIG="$CASE_DIR/janus-config"
  CASE_CODEX_HOME="$CASE_DIR/codex-home"
  mkdir -p "$CASE_CONFIG" "$CASE_CODEX_HOME"
  printf 'JANUS_BASE_URL=https://janus.test/v1/\nJANUS_API_KEY=%s\n' "$SECRET" \
    > "$CASE_CONFIG/router.conf"
  : > "$CASE_DIR/codex.log"
}
run_control() {
  env PATH="$TMP/bin:/usr/bin:/bin" HOME="$CASE_DIR/home" \
    CODEX_HOME="$CASE_CODEX_HOME" JANUS_LAUNCHER_CONFIG_DIR="$CASE_CONFIG" \
    JANUS_TEST_CODEX_LOG="$CASE_DIR/codex.log" "$CONTROL" "$@"
}
run_direct_enable() {
  local login_mode="$1" model="${2:-provider/model-alpha}"
  env PATH="$TMP/bin:/usr/bin:/bin" HOME="$CASE_DIR/home" \
    CODEX_HOME="$CASE_CODEX_HOME" JANUS_LAUNCHER_CONFIG_DIR="$CASE_CONFIG" \
    JANUS_TEST_CODEX_LOG="$CASE_DIR/codex.log" JANUS_TEST_LOGIN_MODE="$login_mode" \
    bash -c '
      source "$1/lib/janus_api.sh"
      source "$1/lib/janus_config.sh"
      source "$1/lib/janus_runtime.sh"
      source "$1/lib/janus_codex_app.sh"
      test_codex_binary="$2/bin/codex"
      janus_codex_app_binary() { printf "%s\n" "$test_codex_binary"; }
      JANUS_BASE_URL=https://janus.test
      JANUS_CATALOG_JSON='"'"'{"data":[{"id":"provider/model-alpha"},{"id":"provider/model-beta"}]}'"'"'
      janus_codex_app_enable "$3" "$1/bin/janus-control"
    ' _ "$ROOT" "$TMP" "$model"
}

new_case lifecycle
original="$CASE_DIR/original-config.toml"
cat > "$original" <<'TOML'
# Personal Codex settings; these bytes must come back after disable.
model = "native-model"
model_provider = "openai"
[history]
persistence = "save-all"

[features]
web_search = true
TOML
cp "$original" "$CASE_CODEX_HOME/config.toml"

status="$(run_control codex-app status)"
[[ "$status" == 'Codex app integration: disabled' ]] || fail 'initial status must be disabled'

enabled="$(run_direct_enable authenticated provider/model-beta)"
assert_contains "$enabled" 'enabled for provider/model-beta (2 Janus models)' 'enable summary'
assert_not_contains "$enabled" "$SECRET" 'enable output secret containment'
config="$(<"$CASE_CODEX_HOME/config.toml")"
assert_contains "$config" '# BEGIN janus-launcher-codex-app-managed' 'managed root block'
assert_contains "$config" 'model = "provider/model-beta"' 'selected app model'
assert_contains "$config" 'model_provider = "janus"' 'managed provider selection'
assert_contains "$config" '[model_providers.janus.auth]' 'provider auth helper table'
assert_contains "$config" 'args = ["codex-token", "https://janus.test/v1"]' 'provider auth helper command and URL scope'
assert_not_contains "$config" "$SECRET" 'generated Codex config secret containment'
[[ "$(mode "$CASE_CODEX_HOME/config.toml")" == 600 ]] || fail 'managed Codex config mode'
[[ "$(mode "$CASE_CONFIG/codex-app-state.json")" == 600 ]] || fail 'Codex app state mode'
[[ "$(mode "$CASE_CONFIG/codex-app-models.json")" == 600 ]] || fail 'Codex app catalog mode'

status="$(run_control codex-app status)"
assert_contains "$status" 'Codex app integration: enabled' 'enabled status'
assert_contains "$status" 'model = "provider/model-beta"' 'enabled status model'
assert_contains "$status" 'Catalog models: 2' 'enabled status count'
assert_not_contains "$status" "$SECRET" 'status secret containment'
pass 'enable and status install a managed provider without leaking credentials'

jq -e '
  [.models[].slug] == ["provider/model-alpha", "provider/model-beta"] and
  [.models[].display_name] == ["provider/model-alpha", "provider/model-beta"] and
  all(.models[]; .description == "Janus catalog model" and
    .visibility == "list" and .supported_in_api == true and
    .default_reasoning_level == "medium" and .context_window == 32768 and
    .input_modalities == ["text"] and .supports_search_tool == false)
' "$CASE_CONFIG/codex-app-models.json" >/dev/null || fail 'generated catalog does not contain exact Janus model entries'
if [[ -s "$CASE_DIR/codex.log" ]]; then
  [[ "$(grep -c '^ARG=<debug>$' "$CASE_DIR/codex.log")" -eq 2 ]] || fail 'Codex catalog and config validation probe count'
  grep -q '^ARG=<models>$' "$CASE_DIR/codex.log" || fail 'Codex bundled catalog probe missing models argument'
  [[ "$(grep -c '^ARG=<--bundled>$' "$CASE_DIR/codex.log")" -eq 1 ]] || fail 'Codex bundled catalog probe count'
fi
pass 'model catalog is generated from Janus IDs and bundled Codex metadata'

token="$(run_control codex-token https://janus.test/v1)"
[[ "$token" == "$SECRET" ]] || fail 'Codex auth helper did not return the configured token exactly'
for artifact in "$CASE_CODEX_HOME/config.toml" "$CASE_CONFIG/codex-app-state.json" \
  "$CASE_CONFIG/codex-app-models.json" "$CASE_DIR/codex.log"; do
  ! grep -F "$SECRET" "$artifact" >/dev/null || fail "secret leaked into $artifact"
done
for bad_expected_url in '' https://other.test/v1; do
  set +e
  if [[ -n "$bad_expected_url" ]]; then
    bad_helper="$(run_control codex-token "$bad_expected_url" 2>&1)"; bad_helper_rc=$?
  else
    bad_helper="$(run_control codex-token 2>&1)"; bad_helper_rc=$?
  fi
  set -e
  [[ $bad_helper_rc -eq 2 && -z "$bad_helper" ]] || fail 'unscoped or mismatched token helper invocation must fail silently'
done
pass 'secret helper is narrow and secrets never enter generated artifacts or probe arguments'

disabled="$(run_control codex-app disable)"
assert_contains "$disabled" 'previous model/provider settings restored' 'disable summary'
cmp -s "$original" "$CASE_CODEX_HOME/config.toml" || fail 'disable did not restore config.toml byte-for-byte'
[[ ! -e "$CASE_CONFIG/codex-app-state.json" ]] || fail 'disable retained integration state'
[[ "$(run_control codex-app status)" == 'Codex app integration: disabled' ]] || fail 'disabled status'
pass 'disable restores the original Codex config exactly'

new_case owned-catalog
catalog_original="$CASE_DIR/original.toml"
cat > "$catalog_original" <<'TOML'
model_catalog_json = "/Users/me/models.json"
[history]
persistence = "save-all"
TOML
cp "$catalog_original" "$CASE_CODEX_HOME/config.toml"
set +e
refused="$(run_direct_enable authenticated provider/model-alpha 2>&1)"; refused_rc=$?
set -e
[[ $refused_rc -eq 2 ]] || fail "user-owned catalog refusal status: $refused_rc"
assert_contains "$refused" 'refusing to replace user-owned model_catalog_json' 'user-owned catalog refusal'
assert_not_contains "$refused" "$SECRET" 'catalog refusal secret containment'
cmp -s "$catalog_original" "$CASE_CODEX_HOME/config.toml" || fail 'catalog refusal changed user config'
[[ ! -e "$CASE_CONFIG/codex-app-state.json" && ! -e "$CASE_CONFIG/codex-app-models.json" ]] ||
  fail 'catalog refusal left managed artifacts'
pass 'enable refuses a user-owned model catalog without mutation'

new_case owned-provider
provider_original="$CASE_DIR/original.toml"
cat > "$provider_original" <<'TOML'
model = "native-model"
[model_providers.janus]
name = "My own Janus provider"
base_url = "https://mine.test/v1"
TOML
cp "$provider_original" "$CASE_CODEX_HOME/config.toml"
set +e
refused="$(run_direct_enable authenticated provider/model-alpha 2>&1)"; refused_rc=$?
set -e
[[ $refused_rc -eq 2 ]] || fail "user-owned provider refusal status: $refused_rc"
assert_contains "$refused" 'refusing to replace user-owned model_providers.janus' 'user-owned provider refusal'
assert_not_contains "$refused" "$SECRET" 'provider refusal secret containment'
cmp -s "$provider_original" "$CASE_CODEX_HOME/config.toml" || fail 'provider refusal changed user config'
[[ ! -e "$CASE_CONFIG/codex-app-state.json" && ! -e "$CASE_CONFIG/codex-app-models.json" ]] ||
  fail 'provider refusal left managed artifacts'
pass 'enable refuses a user-owned Janus provider without mutation'

new_case authenticated
printf '# authenticated baseline\n[history]\npersistence = "save-all"\n' > "$CASE_CODEX_HOME/config.toml"
authenticated="$(run_direct_enable authenticated)"
assert_contains "$authenticated" 'enabled for provider/model-alpha' 'authenticated enable summary'
grep -Fq '# BEGIN janus-launcher-codex-app-managed' "$CASE_CODEX_HOME/config.toml" ||
  fail 'authenticated Codex session did not enable integration'
grep -q '^ARG=<login>$' "$CASE_DIR/codex.log" || fail 'authenticated enable did not probe Codex login status'
grep -q '^ARG=<status>$' "$CASE_DIR/codex.log" || fail 'authenticated login status probe arguments'
pass 'confirmed ChatGPT authentication permits app integration'

for login_mode in signed-out unknown api-key; do
  new_case "auth-$login_mode"
  auth_original="$CASE_DIR/original.toml"
  printf '# authentication refusal baseline\n[history]\npersistence = "save-all"\n' > "$auth_original"
  cp "$auth_original" "$CASE_CODEX_HOME/config.toml"
  set +e
  auth_refused="$(run_direct_enable "$login_mode" 2>&1)"; auth_rc=$?
  set -e
  [[ $auth_rc -ne 0 ]] || fail "$login_mode authentication state was accepted"
  assert_contains "$auth_refused" 'Codex' "$login_mode authentication diagnostic"
  assert_not_contains "$auth_refused" "$SECRET" "$login_mode authentication secret containment"
  cmp -s "$auth_original" "$CASE_CODEX_HOME/config.toml" ||
    fail "$login_mode authentication refusal changed config.toml"
  [[ -z "$(find "$CASE_CONFIG" -type f ! -name router.conf -print -quit)" ]] ||
    fail "$login_mode authentication refusal created Janus app state"
  pass "$login_mode authentication fails closed without configuration mutation"
done

# Override binary discovery in a fresh shell so this remains deterministic on
# machines where the desktop app bundles Codex outside PATH.
new_case missing-codex
set +e
missing="$(env PATH="$TMP/bin:/usr/bin:/bin" HOME="$CASE_DIR/home" \
  CODEX_HOME="$CASE_CODEX_HOME" JANUS_LAUNCHER_CONFIG_DIR="$CASE_CONFIG" \
  bash -c '
    source "$1/lib/janus_api.sh"
    source "$1/lib/janus_config.sh"
    source "$1/lib/janus_runtime.sh"
    source "$1/lib/janus_codex_app.sh"
    janus_codex_app_binary() { return 127; }
    JANUS_BASE_URL=https://janus.test
    JANUS_CATALOG_JSON='"'"'{"data":[{"id":"provider/model-alpha"}]}'"'"'
    janus_codex_app_enable provider/model-alpha "$1/bin/janus-control"
  ' _ "$ROOT" 2>&1)"; missing_rc=$?
set -e
[[ $missing_rc -eq 127 ]] || fail "missing Codex status: $missing_rc"
assert_contains "$missing" 'Codex binary not found' 'missing Codex diagnostic'
assert_not_contains "$missing" "$SECRET" 'missing Codex secret containment'
[[ ! -e "$CASE_CODEX_HOME/config.toml" && ! -e "$CASE_CONFIG/codex-app-state.json" &&
  ! -e "$CASE_CONFIG/codex-app-models.json" ]] || fail 'missing Codex changed app integration state'
pass 'missing Codex fails actionably before changing configuration'

printf 'All Codex app integration tests passed.\n'
