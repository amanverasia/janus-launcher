#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/lib/janus_codex_router.sh"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }
digest_tree() {
  local directory="$1"
  find "$directory" -type f -print0 | sort -z | xargs -0 shasum -a 256
}

[[ -f "$BRIDGE" ]] || fail 'Codex Router bridge library is missing'

SECRET='router-bridge secret $dollar `backtick`; semicolon'
CATALOG='{"data":[{"id":"provider/model-alpha"},{"id":"team/model.beta"}]}'

new_case() {
  local name="$1"
  CASE_DIR="$TMP/$name"
  CASE_HOME="$CASE_DIR/home"
  CASE_CODEX_HOME="$CASE_DIR/codex-home"
  CASE_STATE="$CASE_CODEX_HOME/codex-router"
  CASE_ROUTER="$CASE_DIR/router-checkout"
  CASE_CONFIG="$CASE_DIR/janus-config"
  COMMAND_LOG="$CASE_DIR/router-commands.log"
  mkdir -p "$CASE_HOME" "$CASE_STATE" "$CASE_ROUTER/config" "$CASE_ROUTER/bin" "$CASE_CONFIG"
  : > "$COMMAND_LOG"

  cat > "$CASE_CODEX_HOME/config.toml" <<EOF
# User-owned root configuration; every byte must remain unchanged.
model = "native-model"
model_catalog_json = "$CASE_STATE/merged-models.json"
[history]
persistence = "save-all"
EOF
  printf '{"models":[]}\n' > "$CASE_STATE/merged-models.json"
  cat > "$CASE_STATE/install-manifest.json" <<EOF
{
  "version": 1,
  "current": {
    "packageVersion": "0.4.0-beta.2",
    "sourceRoot": "$CASE_ROUTER",
    "target": "codex"
  },
  "history": []
}
EOF
  cat > "$CASE_ROUTER/package.json" <<'EOF'
{"name":"codex-model-router","version":"0.4.0-beta.2"}
EOF
  cat > "$CASE_ROUTER/config/providers.json" <<'EOF'
{
  "version": 1,
  "providers": [
    {
      "id": "deepseek",
      "displayName": "DeepSeek API",
      "kind": "openai-compatible",
      "baseUrl": "https://api.deepseek.test/v1",
      "credential": {"environment":["DEEPSEEK_API_KEY"],"file":"deepseek-api-key.secret","legacyFiles":[],"keychainServices":[],"prompt":"DeepSeek key"}
    }
  ],
  "models": [
    {"slug":"deepseek/existing","gatewayModel":"deepseek-existing","upstreamModel":"existing","provider":"deepseek","listed":true,"priority":10}
  ]
}
EOF
  printf '{"version":1,"providers":["deepseek"]}\n' > "$CASE_STATE/enabled-providers.json"
  cat > "$CASE_STATE/user-models.json" <<'EOF'
{"version":1,"models":[{"slug":"deepseek/personal","gatewayModel":"deepseek-personal","upstreamModel":"personal","provider":"deepseek","listed":true,"priority":100}]}
EOF

  for command in install start control refresh-catalog provider-key; do
    cat > "$CASE_ROUTER/bin/$command" <<'SH'
#!/usr/bin/env bash
printf 'COMMAND=%s\n' "$(basename -- "$0")" >> "$JANUS_TEST_ROUTER_COMMAND_LOG"
printf 'ARG=<%s>\n' "$@" >> "$JANUS_TEST_ROUTER_COMMAND_LOG"
printf 'STDIN=' >> "$JANUS_TEST_ROUTER_COMMAND_LOG"
IFS= read -r input || true
printf '<%s>\n' "$input" >> "$JANUS_TEST_ROUTER_COMMAND_LOG"
exit 0
SH
    chmod +x "$CASE_ROUTER/bin/$command"
  done
}

run_bridge() {
  local operation="$1"
  shift
  env HOME="$CASE_HOME" CODEX_HOME="$CASE_CODEX_HOME" \
    JANUS_LAUNCHER_CONFIG_DIR="$CASE_CONFIG" \
    JANUS_LAUNCHER_CODEX_ROUTER_DIR="$CASE_ROUTER" \
    JANUS_TEST_ROUTER_COMMAND_LOG="$COMMAND_LOG" \
    JANUS_TEST_BASE_URL='https://janus.test/v1/' JANUS_TEST_API_KEY="$SECRET" \
    JANUS_TEST_CATALOG="$CATALOG" \
    bash -c '
      source "$1/lib/janus_api.sh"
      source "$1/lib/janus_config.sh"
      source "$1/lib/janus_runtime.sh"
      source "$1/lib/janus_codex_app.sh"
      source "$1/lib/janus_codex_router.sh"
      JANUS_BASE_URL="$JANUS_TEST_BASE_URL"
      JANUS_API_KEY="$JANUS_TEST_API_KEY"
      JANUS_CATALOG_JSON="$JANUS_TEST_CATALOG"
      operation="$2"
      shift 2
      "janus_codex_router_$operation" "$@"
    ' _ "$ROOT" "$operation" "$@"
}

run_control() {
  env HOME="$CASE_HOME" CODEX_HOME="$CASE_CODEX_HOME" \
    JANUS_LAUNCHER_CONFIG_DIR="$CASE_CONFIG" \
    JANUS_LAUNCHER_CODEX_ROUTER_DIR="$CASE_ROUTER" \
    JANUS_TEST_ROUTER_COMMAND_LOG="$COMMAND_LOG" \
    "$ROOT/bin/janus-control" codex-app "$@"
}

new_case recognized
run_bridge owns_catalog || fail 'supported Codex Router-owned catalog was not recognized'
pass 'stock Codex Router 0.4.0-beta.2 ownership is detected'

status_output="$(run_control status)"
assert_contains "$status_output" 'externally managed' 'control status reports Router ownership'
assert_contains "$status_output" 'Janus changes: none' 'control status reports no Janus mutations'
disable_output="$(run_control disable)"
assert_contains "$disable_output" 'nothing to disable' 'control disable is a no-op for Router ownership'
[[ ! -s "$COMMAND_LOG" ]] || fail 'Router-owned status/disable invoked a Router command'
pass 'janus-control auto-routes Router-owned status and disable without side effects'

before="$(digest_tree "$CASE_DIR")"
set +e
output="$(run_bridge enable provider/model-alpha 2>&1)"; status=$?
set -e
[[ $status -ne 0 ]] || fail 'Router-owned catalog was unsafely modified'
assert_contains "$output" 'Codex Router' 'Router ownership refusal names the conflicting integration'
assert_contains "$output" '0.4.0-beta.2' 'Router ownership refusal names the supported detected version'
assert_contains "$output" 'safe' 'Router ownership refusal explains the missing safe extension point'
after="$(digest_tree "$CASE_DIR")"
[[ "$before" == "$after" ]] || fail 'Router ownership refusal changed checkout or user state'
[[ ! -s "$COMMAND_LOG" ]] || fail 'Router ownership refusal invoked a Router command or service'
[[ -z "$(find "$CASE_CONFIG" -maxdepth 1 -name 'codex-router-bridge-*' -print -quit)" ]] ||
  fail 'Router ownership refusal created bridge state or backups'
[[ ! -e "$CASE_STATE/janus-api-key.secret" ]] || fail 'Router ownership refusal persisted a credential'
for artifact in "$CASE_ROUTER/config/providers.json" "$CASE_STATE/merged-models.json" \
  "$CASE_STATE/enabled-providers.json" "$CASE_STATE/user-models.json" "$COMMAND_LOG"; do
  ! grep -F "$SECRET" "$artifact" >/dev/null || fail "secret leaked into $artifact"
done
jq -e '.providers == ["deepseek"]' "$CASE_STATE/enabled-providers.json" >/dev/null ||
  fail 'Router ownership refusal changed enabled providers'
jq -e '[.providers[].id] == ["deepseek"] and [.models[].provider] == ["deepseek"]' \
  "$CASE_ROUTER/config/providers.json" >/dev/null || fail 'Router ownership refusal registered Janus'
pass 'Router-owned enable fails safely without registry, model, key, state, argv, log, or service effects'

new_case ordinary-catalog
printf 'model_catalog_json = "%s"\n' "$CASE_CODEX_HOME/personal-models.json" > "$CASE_CODEX_HOME/config.toml"
printf '{"models":[]}\n' > "$CASE_CODEX_HOME/personal-models.json"
set +e
run_bridge owns_catalog >/dev/null 2>&1; ordinary_status=$?
set -e
[[ $ordinary_status -eq 1 ]] || fail "ordinary user catalog ownership status: $ordinary_status"
pass 'ordinary user catalogs are not mistaken for Codex Router ownership'

for invalid in package-version manifest-version manifest-schema registry-schema missing-layout; do
  new_case "invalid-$invalid"
  case "$invalid" in
    package-version) jq '.version="0.5.0"' "$CASE_ROUTER/package.json" > "$CASE_DIR/x"; mv "$CASE_DIR/x" "$CASE_ROUTER/package.json" ;;
    manifest-version) jq '.current.packageVersion="0.5.0"' "$CASE_STATE/install-manifest.json" > "$CASE_DIR/x"; mv "$CASE_DIR/x" "$CASE_STATE/install-manifest.json" ;;
    manifest-schema) jq '.version=2' "$CASE_STATE/install-manifest.json" > "$CASE_DIR/x"; mv "$CASE_DIR/x" "$CASE_STATE/install-manifest.json" ;;
    registry-schema) jq '.version=2' "$CASE_ROUTER/config/providers.json" > "$CASE_DIR/x"; mv "$CASE_DIR/x" "$CASE_ROUTER/config/providers.json" ;;
    missing-layout) rm "$CASE_ROUTER/config/providers.json" ;;
  esac
  invalid_before="$(digest_tree "$CASE_DIR")"
  set +e
  run_bridge owns_catalog >/dev/null 2>&1; invalid_status=$?
  set -e
  [[ $invalid_status -eq 2 ]] || fail "$invalid did not return unsafe/unknown status 2"
  set +e
  invalid_output="$(run_bridge enable provider/model-alpha 2>&1)"; invalid_enable_status=$?
  set -e
  [[ $invalid_enable_status -ne 0 ]] || fail "$invalid layout was accepted for enable"
  assert_contains "$invalid_output" 'Codex Router' "$invalid refusal diagnostic"
  invalid_after="$(digest_tree "$CASE_DIR")"
  [[ "$invalid_before" == "$invalid_after" ]] || fail "$invalid refusal mutated fixture state"
  [[ ! -s "$COMMAND_LOG" ]] || fail "$invalid refusal invoked a Router command"
done
pass 'unknown Router versions and layouts fail closed without mutation'

printf 'All Codex Router bridge tests passed.\n'
