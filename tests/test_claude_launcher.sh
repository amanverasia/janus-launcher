#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/bin/claude-janus"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3 (unexpected: $2)"; }

mkdir -p "$TMP/bin" "$TMP/config/janus-launcher"
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'ARG[%d]=%s\n' "$#" "$*"
printf 'OWNED=%s|%s|%s|%s|%s|%s|%s\n' \
  "${ANTHROPIC_BASE_URL-<unset>}" "${ANTHROPIC_AUTH_TOKEN-<unset>}" \
  "${ANTHROPIC_API_KEY-<unset>}" "${ANTHROPIC_DEFAULT_OPUS_MODEL-<unset>}" \
  "${ANTHROPIC_DEFAULT_SONNET_MODEL-<unset>}" "${ANTHROPIC_DEFAULT_HAIKU_MODEL-<unset>}" \
  "${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}"
printf 'UNSETS=%s|%s SENTINEL=%s LEGACY=%s\n' \
  "${ANTHROPIC_MODEL-<unset>}" "${OPENROUTER_API_KEY-<unset>}" \
  "${UNRELATED_SENTINEL-<unset>}" "${LEGACY_SENTINEL-<unset>}"
exit "${FAKE_CLAUDE_EXIT:-0}"
SH
chmod +x "$TMP/bin/claude"
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */v1/health) exit 0 ;;
    */v1/models)
      if [[ -n "${JANUS_TEST_CATALOG:-}" ]]; then
        printf '%s\n' "$JANUS_TEST_CATALOG"
      else
        printf '%s\n' '{"data":[{"id":"route/opus"},{"id":"route/sonnet"},{"id":"route/haiku"},{"id":"route/subagent"},{"id":"route/caller"},{"id":"openrouter/anthropic/claude-opus-4.8"},{"id":"deepseek/deepseek-v4-pro"},{"id":"zhipu/glm-4.7"}]}'
      fi
      exit 0
      ;;
  esac
done
exit 7
SH
chmod +x "$TMP/bin/curl"

CONFIG_DIR="$TMP/config/janus-launcher"
export JANUS_LAUNCHER_CONFIG_DIR="$CONFIG_DIR"
export JANUS_LAUNCHER_BASE_URL='https://janus.test'
export JANUS_LAUNCHER_API_KEY='test-key'
export JANUS_LAUNCHER_CLAUDE_TIER=sonnet
BASE_ENV=(PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" UNRELATED_SENTINEL=kept
  ANTHROPIC_MODEL=remove-me OPENROUTER_API_KEY=remove-me)

write_valid() {
  cat > "$CONFIG_DIR/claude-mappings.conf" <<'EOF'
OPUS_MODEL=route/opus
SONNET_MODEL=route/sonnet
HAIKU_MODEL=route/haiku
SUBAGENT_MODEL=route/subagent
DEFAULT_TIER=sonnet
EOF
  chmod 600 "$CONFIG_DIR/claude-mappings.conf"
}
run_launcher() { env "${BASE_ENV[@]}" "$WRAPPER" "$@" 2>&1; }
write_valid
[[ "$(stat -c %a "$CONFIG_DIR/claude-mappings.conf")" == 600 ]] || fail 'mapping file permissions'

out="$(run_launcher -p hello)"
assert_contains "$out" 'ARG[4]=--model sonnet -p hello' 'default tier arguments'
assert_contains "$out" 'OWNED=https://janus.test|test-key||route/opus|route/sonnet|route/haiku|route/subagent' 'exact Anthropic child contract'
assert_contains "$out" 'UNSETS=<unset>|<unset> SENTINEL=kept' 'unsets and unrelated inheritance'
assert_not_contains "$out" 'JANUS_LAUNCHER_CODEX' 'no Codex child contract'
pass 'catalog-backed mappings and child environment'

out="$(run_launcher --model route/caller -p hi)"
assert_contains "$out" 'ARG[4]=--model route/caller -p hi' 'caller separated model wins'
out="$(run_launcher --model=route/caller -p hi)"
assert_contains "$out" 'ARG[3]=--model=route/caller -p hi' 'caller assigned model wins'
set +e; out="$(run_launcher --model)"; rc=$?; set -e
[[ $rc -eq 2 ]] && assert_contains "$out" '--model requires a value' 'bare model diagnostic' || fail 'bare --model fails'
pass 'caller model precedence and validation'

out="$(run_launcher -p prompt -- --model route/stale --model=route/stale)"
assert_contains "$out" 'ARG[8]=--model sonnet -p prompt -- --model route/stale --model=route/stale' 'delimiter arguments preserved with launcher tier'
pass 'Claude delimiter stops model parsing'

for arg in -h --help -V --version help; do
  rm -f "$CONFIG_DIR/claude-mappings.conf"
  out="$(env PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/no-config" "$WRAPPER" "$arg" 2>&1)"
  assert_contains "$out" "ARG[1]=$arg" "top-level passthrough $arg"
  assert_not_contains "$out" 'router configuration' "top-level passthrough setup $arg"
done
write_valid
for encoded in 'exec|--help' '-p|text -h here' '-v|'; do
  IFS='|' read -r first second <<<"$encoded"
  set +e
  if [[ -n "$second" ]]; then out="$(env -u JANUS_LAUNCHER_CONFIG_DIR -u JANUS_LAUNCHER_BASE_URL -u JANUS_LAUNCHER_API_KEY PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/no-config" "$WRAPPER" "$first" "$second" 2>&1)"; else out="$(env -u JANUS_LAUNCHER_CONFIG_DIR -u JANUS_LAUNCHER_BASE_URL -u JANUS_LAUNCHER_API_KEY PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/no-config" "$WRAPPER" "$first" 2>&1)"; fi
  rc=$?; set -e
  [[ $rc -ne 0 ]] || fail "$first is not top-level passthrough"
  assert_contains "$out" 'router configuration' "$first requires setup"
done
pass 'exact top-level passthrough semantics'

fixture_fails() {
  local name="$1" content="$2"
  printf '%b' "$content" > "$CONFIG_DIR/claude-mappings.conf"
  set +e; local output; output="$(run_launcher -p hi)"; local rc=$?; set -e
  [[ $rc -ne 0 ]] || fail "strict mapping fixture: $name"
  assert_not_contains "$output" 'test-key' "strict fixture redacts key: $name"
}
fixture_fails missing 'OPUS_MODEL=route/opus\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nDEFAULT_TIER=sonnet\n'
fixture_fails duplicate 'OPUS_MODEL=route/opus\nOPUS_MODEL=route/opus\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nSUBAGENT_MODEL=route/subagent\nDEFAULT_TIER=sonnet\n'
fixture_fails unknown 'OPUS_MODEL=route/opus\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nSUBAGENT_MODEL=route/subagent\nDEFAULT_TIER=sonnet\nWAT=no\n'
fixture_fails tier 'OPUS_MODEL=route/opus\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nSUBAGENT_MODEL=route/subagent\nDEFAULT_TIER=subagent\n'
fixture_fails empty 'OPUS_MODEL=\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nSUBAGENT_MODEL=route/subagent\nDEFAULT_TIER=sonnet\n'
fixture_fails newline-corruption 'OPUS_MODEL=route/opus\nbroken\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nSUBAGENT_MODEL=route/subagent\nDEFAULT_TIER=sonnet\n'
fixture_fails carriage-return 'OPUS_MODEL=route/opus\r\nSONNET_MODEL=route/sonnet\nHAIKU_MODEL=route/haiku\nSUBAGENT_MODEL=route/subagent\nDEFAULT_TIER=sonnet\n'
pass 'strict mapping parser fixtures'

rm -f "$CONFIG_DIR/claude-mappings.conf"
custom_catalog='{"data":[{"id":"catalog/one"},{"id":"catalog/two"},{"id":"catalog/three"},{"id":"catalog/four"}]}'
set +e
out="$(env "${BASE_ENV[@]}" JANUS_TEST_CATALOG="$custom_catalog" "$WRAPPER" -p hi </dev/null 2>&1)"
rc=$?
set -e
[[ $rc -eq 2 ]] || fail "missing Claude mappings must fail noninteractively with status 2, got $rc"
assert_contains "$out" 'Claude mappings are missing' 'missing mappings noninteractive category'
assert_contains "$out" 'Run claude-janus interactively' 'missing mappings corrective guidance'
[[ ! -e "$CONFIG_DIR/claude-mappings.conf" ]] || fail 'missing mappings failure must not persist defaults'
pass 'missing Claude mappings fail noninteractively without persistence'

write_valid
perl -0pi -e 's#route/subagent#route/stale#' "$CONFIG_DIR/claude-mappings.conf"
set +e; out="$(run_launcher -p hi)"; rc=$?; set -e
[[ $rc -ne 0 ]] && assert_contains "$out" 'route/stale' 'stale mapping diagnostic' || fail 'stale mapping fails'
write_valid
set +e; out="$(run_launcher --model route/stale)"; rc=$?; set -e
[[ $rc -ne 0 ]] && assert_contains "$out" 'route/stale' 'stale caller model diagnostic' || fail 'stale caller model fails'
pass 'catalog validation covers mappings and caller model'

out="$(env "${BASE_ENV[@]}" JANUS_LAUNCHER_DRY_RUN=1 "$WRAPPER" -p hi 2>&1)"
assert_contains "$out" 'ANTHROPIC_AUTH_TOKEN=<set>' 'dry-run token marker'
assert_not_contains "$out" 'test-key' 'dry-run secret redaction'
out="$(env "${BASE_ENV[@]}" CLAUDE_JANUS_DRYRUN=1 "$WRAPPER" -p hi 2>&1)"
assert_contains "$out" 'ARG[4]=' 'legacy dry-run ignored'
pass 'new dry-run and legacy dry-run ignored'

mkdir -p "$TMP/legacy/claude-janus"
printf 'OPUS_MODEL=legacy/value\n' > "$TMP/legacy/claude-janus/mappings.conf"
out="$(env "${BASE_ENV[@]}" XDG_CONFIG_HOME="$TMP/legacy" JANUS_BASE_URL=https://legacy-override JANUS_API_KEY=legacy-override CLAUDE_JANUS_CONFIG="$TMP/legacy/router.conf" CLAUDE_JANUS_SETUP_BASE_URL=https://legacy CLAUDE_JANUS_SETUP_API_KEY=legacy CLAUDE_JANUS_TIER=opus CLAUDE_JANUS_SKIP_CHECK=1 CLAUDE_JANUS_STRICT_CHECK=1 LEGACY_SENTINEL=inherited "$WRAPPER" -p hi 2>&1)"
assert_contains "$out" 'ARG[4]=--model sonnet -p hi' 'legacy tier ignored'
assert_contains "$out" 'OWNED=https://janus.test|test-key|' 'legacy router overrides ignored'
assert_contains "$out" 'LEGACY=inherited' 'unrelated legacy-named sentinel inherited'
assert_not_contains "$out" 'legacy/value' 'legacy state ignored'
pass 'legacy launcher state and overrides ignored'

set +e
env "${BASE_ENV[@]}" FAKE_CLAUDE_EXIT=37 "$WRAPPER" -p hi >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 37 ]] || fail 'child exit status propagation'
pass 'child exit status propagation'

printf 'All Claude launcher tests passed.\n'
