#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/bin/codex-janus"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3 (missing: $2)"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3 (unexpected: $2)"; }
quote_arg() { printf '%q' "$1"; }

mkdir -p "$TMP/bin" "$TMP/config"
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'COUNT=%d\n' "$#"
i=0
for arg in "$@"; do
  printf 'ARG[%d]=%q\n' "$i" "$arg"
  ((i += 1))
done
if [[ -v JANUS_LAUNCHER_CODEX_API_KEY ]]; then
  printf 'KEY_SET=yes KEY_MATCH=%s\n' "$([[ "$JANUS_LAUNCHER_CODEX_API_KEY" == "$EXPECTED_CODEX_KEY" ]] && printf yes || printf no)"
else
  printf 'KEY_SET=no KEY_MATCH=no\n'
fi
SH
chmod +x "$TMP/bin/codex"
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */v1/health) exit 0 ;;
    */v1/models)
      printf '%s\n' '{"data":[{"id":"model-a"}]}'
      exit 0
      ;;
  esac
done
exit 7
SH
chmod +x "$TMP/bin/curl"

SECRET='secret value with spaces $dollar `backtick`; semicolon'
BASE_ENV=(PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home"
  JANUS_LAUNCHER_CONFIG_DIR="$TMP/config"
  JANUS_LAUNCHER_API_KEY="$SECRET" EXPECTED_CODEX_KEY="$SECRET")
run_launcher() { env "${BASE_ENV[@]}" "$WRAPPER" "$@" 2>&1; }
run_with_url() {
  local url="$1"
  shift
  env "${BASE_ENV[@]}" JANUS_LAUNCHER_BASE_URL="$url" "$WRAPPER" "$@" 2>&1
}
expect_failure() {
  local label="$1" expected="$2"
  shift 2
  local output rc
  set +e
  output="$(run_with_url 'https://janus.test' "$@")"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "$label must fail"
  assert_contains "$output" "$expected" "$label diagnostic"
  assert_not_contains "$output" "$SECRET" "$label secret containment"
}

# Exact Codex model spellings must remain byte-for-byte and must not gain a
# second launcher model. Provider arguments precede every caller vector.
for form in separated-long assigned-long separated-short attached-short; do
  case "$form" in
    separated-long) args=(--model model-a -c 'features.example=true' exec 'prompt text') ;;
    assigned-long) args=(--model=model-a -c 'features.example=true' exec 'prompt text') ;;
    separated-short) args=(-m model-a -c 'features.example=true' exec 'prompt text') ;;
    attached-short) args=(-mmodel-a -c 'features.example=true' exec 'prompt text') ;;
  esac
  out="$(run_with_url 'https://janus.test/' "${args[@]}")"
  assert_contains "$out" "COUNT=$((10 + ${#args[@]}))" "$form exact argument count"
  assert_contains "$out" 'ARG[0]=-c' "$form provider arguments first"
  assert_contains "$out" 'ARG[1]=model_provider=\"janus\"' "$form provider selection"
  assert_contains "$out" 'ARG[3]=model_providers.janus.name=\"Janus\"' "$form provider name"
  assert_contains "$out" 'ARG[5]=model_providers.janus.base_url=\"https://janus.test/v1\"' "$form normalized API root"
  assert_contains "$out" 'ARG[7]=model_providers.janus.env_key=\"JANUS_LAUNCHER_CODEX_API_KEY\"' "$form environment key"
  assert_contains "$out" 'ARG[9]=model_providers.janus.wire_api=\"responses\"' "$form Responses API"
  for i in "${!args[@]}"; do
    assert_contains "$out" "ARG[$((i + 10))]=$(quote_arg "${args[$i]}")" "$form preserves caller argument $i"
  done
  [[ "$(grep -c 'model-a' <<<"$out")" -eq 1 ]] || fail "$form has exactly one effective model"
  assert_contains "$out" 'KEY_SET=yes KEY_MATCH=yes' "$form key environment"
  assert_not_contains "$out" "$SECRET" "$form key absent from argv and output"
done
pass 'exact model forms and provider contract'

for item in \
  '-c|model_provider="other"' \
  '-c=model_provider="other"|' \
  '-c=model_providers.janus.base_url="other"|' \
  '--config|model_providers.janus="other"' \
  '--config=model_providers.janus.base_url="other"|'
do
  IFS='|' read -r first second <<<"$item"
  if [[ -n "$second" ]]; then
    expect_failure "owned override $first" 'cannot override launcher-owned Codex provider configuration' "$first" "$second"
  else
    expect_failure "owned override $first" 'cannot override launcher-owned Codex provider configuration' "$first"
  fi
done
expect_failure 'missing -c value' '-c requires a value' -c
expect_failure 'missing --config value' '--config requires a value' --config
expect_failure 'missing --model value' '--model requires a value' --model
expect_failure 'empty assigned model' '--model requires a value' --model=
expect_failure 'missing -m value' '-m requires a value' -m
pass 'owned-key rejection and missing values'

# Owned-looking text outside config option values is ordinary caller input.
args=(exec 'model_provider="prompt"' 'model_providers.janus.base_url="prompt"'
  --config 'features.example=true' --config=history.persistence=save-all
  '-c=features.attached="kept byte-for-byte"')
out="$(run_with_url 'https://janus.test/v1/' --model model-a "${args[@]}")"
for i in "${!args[@]}"; do
  assert_contains "$out" "ARG[$((i + 12))]=$(quote_arg "${args[$i]}")" "unrelated passthrough argument $i"
done
pass 'owned-looking prompts and unrelated config pass through'

parsed="$(env CODEX_JANUS_SOURCE_ONLY=1 bash -c '
  source "$1"
  codex_parse_arguments -m model-a -c -mconfig -c=-mattached exec
  printf "MODEL=%s HAS=%s COUNT=%d CFG=%s ATTACHED=%s\n" "$CODEX_CALLER_MODEL" "$CODEX_HAS_CALLER_MODEL" "${#CODEX_USER_ARGS[@]}" "${CODEX_USER_ARGS[3]}" "${CODEX_USER_ARGS[4]}"
' _ "$WRAPPER")"
[[ "$parsed" == 'MODEL=model-a HAS=1 COUNT=6 CFG=-mconfig ATTACHED=-c=-mattached' ]] || fail "config values must not be parsed as models: $parsed"
pass 'model parser skips configuration values'

# Generated TOML and all command construction remain array-safe. The marker
# would be created if any URL, model, or config value were evaluated as shell.
MARKER="$TMP/evaluated"
SPECIAL_URL="https://janus.test/path space/quote\"/back\\slash/\$(touch $MARKER)/\`touch $MARKER\`;semi"
SPECIAL_MODEL='model space \" \\ $dollar `backtick`; semicolon'
SPECIAL_CONFIG='features.note="space \\ \" $ ` ; $(touch '"$MARKER"')"'
out="$(run_with_url "$SPECIAL_URL" --model "$SPECIAL_MODEL" -c "$SPECIAL_CONFIG")"
expected_root="${SPECIAL_URL%/}/v1"
expected_toml="$(env CODEX_JANUS_SOURCE_ONLY=1 bash -c 'source "$1"; toml_quote_string "$2"' _ "$WRAPPER" "$expected_root")"
assert_contains "$out" "ARG[5]=$(quote_arg "model_providers.janus.base_url=$expected_toml")" 'special URL is one escaped TOML argument'
assert_contains "$out" "ARG[10]=--model" 'special model option preserved'
assert_contains "$out" "ARG[11]=$(quote_arg "$SPECIAL_MODEL")" 'special model is one argument'
assert_contains "$out" "ARG[12]=-c" 'special config option preserved'
assert_contains "$out" "ARG[13]=$(quote_arg "$SPECIAL_CONFIG")" 'special config is one argument'
[[ ! -e "$MARKER" ]] || fail 'shell-significant input was executed'
assert_not_contains "$out" "$SECRET" 'special values keep secret out of argv'
pass 'array safety and shell-significant values'

control_value=$'a\b\f\n\r\t\v\033\177z'
quoted="$(env CODEX_JANUS_SOURCE_ONLY=1 bash -c 'source "$1"; toml_quote_string "$2"' _ "$WRAPPER" "$control_value")"
[[ "$quoted" == '"a\b\f\n\r\t\u000B\u001B\u007Fz"' ]] || fail "TOML control escaping: got $(quote_arg "$quoted")"
locale_after="$(env -u LC_ALL CODEX_JANUS_SOURCE_ONLY=1 bash -c 'source "$1"; toml_quote_string value >/dev/null; printf "%s" "${LC_ALL-unset}"' _ "$WRAPPER")"
[[ "$locale_after" == unset ]] || fail 'TOML quoting must not change caller locale'
pass 'TOML control-character escaping'

printf 'All Codex launcher Task 5 tests passed.\n'
