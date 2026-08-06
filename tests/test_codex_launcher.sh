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
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
quote_arg() { printf '%q' "$1"; }
mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

mkdir -p "$TMP/bin" "$TMP/config"
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'COUNT=%d\n' "$#"
i=0
for arg in "$@"; do
  printf 'ARG[%d]=%q\n' "$i" "$arg"
  ((i += 1))
done
if [[ "${JANUS_LAUNCHER_CODEX_API_KEY+set}" == set ]]; then
  printf 'KEY_SET=yes KEY_MATCH=%s\n' "$([[ "$JANUS_LAUNCHER_CODEX_API_KEY" == "$EXPECTED_CODEX_KEY" ]] && printf yes || printf no)"
else
  printf 'KEY_SET=no KEY_MATCH=no\n'
fi
printf 'UNRELATED_ENV=%s\n' "${UNRELATED_ENV-unset}"
printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-unset}"
secret_names=()
while IFS='=' read -r name value; do
  [[ "$value" == "${EXPECTED_CODEX_KEY:-}" ]] && secret_names+=("$name")
done < <(env)
IFS=$'\n' secret_names=($(printf '%s\n' "${secret_names[@]}" | sort))
IFS=,
printf 'SECRET_ENV_NAMES=%s\n' "${secret_names[*]}"
[[ -n "${CODEX_TEST_STDERR:-}" ]] && printf '%s\n' "$CODEX_TEST_STDERR" >&2
exit "${CODEX_TEST_STATUS:-0}"
SH
chmod +x "$TMP/bin/codex"
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */v1/health)
      printf '%s\n' "$arg" >> "${JANUS_TEST_CURL_LOG:-/dev/null}"
      exit "${JANUS_TEST_HEALTH_STATUS:-0}"
      ;;
    */v1/models)
      printf '%s\n' "$arg" >> "${JANUS_TEST_CURL_LOG:-/dev/null}"
      jq -cn --arg extra "${JANUS_TEST_EXTRA_MODEL:-}" \
        '{data: ([{id:"model-a"}] + if $extra == "" then [] else [{id:$extra}] end)}'
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

for override in \
  ' model_provider = "other"' \
  '"model_provider"="other"' \
  '"model_prov\u0069der"="other"' \
  '"model_prov\U00000069der"="other"' \
  "'model_provider' = \"other\"" \
  'model_providers . janus . base_url = "other"' \
  '"model_providers" . janus . "base_url" = "other"' \
  "model_providers . 'janus' . base_url = \"other\"" \
  'model_providers.janus.extra.descendant = "other"' \
  'model_providers={janus={base_url="https://attacker.test"}}' \
  ' model_providers = {janus={base_url="https://attacker.test"}}' \
  '"model_providers"={janus={base_url="https://attacker.test"}}' \
  "'model_providers' = {janus={base_url=\"https://attacker.test\"}}"
do
  expect_failure "semantic owned override $override" \
    'cannot override launcher-owned Codex provider configuration' -c "$override"
done
pass 'semantic TOML owned-key rejection'

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

parsed="$(env CODEX_JANUS_SOURCE_ONLY=1 bash -c '
  source "$1"
  codex_parse_arguments exec -- --model owned-looking -c model_provider=other --config model_providers.janus.base_url=other -m attached
  printf "MODEL=%s HAS=%s COUNT=%d LAST=%s\n" "$CODEX_CALLER_MODEL" "$CODEX_HAS_CALLER_MODEL" "${#CODEX_USER_ARGS[@]}" "${CODEX_USER_ARGS[${#CODEX_USER_ARGS[@]} - 1]}"
' _ "$WRAPPER")"
[[ "$parsed" == 'MODEL= HAS=0 COUNT=10 LAST=attached' ]] || fail "delimiter must stop Codex wrapper parsing: $parsed"
printf 'MODEL=model-a\n' > "$TMP/config/codex.conf"
out="$(run_with_url 'https://janus.test' exec -- --model owned-looking -c model_provider=other -m model-a)"
assert_contains "$out" 'ARG[10]=--model' 'launcher inserts saved model before delimiter arguments'
assert_contains "$out" 'ARG[13]=--' 'delimiter preserved'
assert_contains "$out" 'ARG[14]=--model' 'post-delimiter model preserved'
assert_contains "$out" 'ARG[16]=-c' 'post-delimiter config preserved'
assert_contains "$out" 'ARG[18]=-m' 'post-delimiter short model preserved'
pass 'Codex delimiter stops wrapper parsing'

# Generated TOML and all command construction remain array-safe. The marker
# would be created if any URL, model, or config value were evaluated as shell.
MARKER="$TMP/evaluated"
SPECIAL_URL="https://janus.test/path space/quote\"/back\\slash/\$(touch $MARKER)/\`touch $MARKER\`;semi"
SPECIAL_MODEL='model space \" \\ $dollar `backtick`; semicolon'
SPECIAL_CONFIG='features.note="space \\ \" $ ` ; $(touch '"$MARKER"')"'
out="$(JANUS_TEST_EXTRA_MODEL="$SPECIAL_MODEL" run_with_url "$SPECIAL_URL" --model "$SPECIAL_MODEL" -c "$SPECIAL_CONFIG")"
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

# Task 6 model state is a strict, single-line format. Values are split only at
# the first '=' so ordinary catalog identifiers round-trip byte-for-byte.
source_codex() {
  env CODEX_JANUS_SOURCE_ONLY=1 bash -c 'source "$1"; shift; "$@"' _ "$WRAPPER" "$@"
}
state="$TMP/config/state.conf"
roundtrip='provider/name.with:dash_under score=high=exact'
source_codex codex_save_model "$state" "$roundtrip"
[[ "$(mode "$state")" == 600 ]] || fail 'Codex state mode must be 600'
[[ "$(<"$state")" == "MODEL=$roundtrip" ]] || fail 'Codex state must contain exactly one MODEL line'
loaded="$(env CODEX_JANUS_SOURCE_ONLY=1 bash -c 'source "$1"; codex_load_model "$2"; printf "%s" "$CODEX_SAVED_MODEL"' _ "$WRAPPER" "$state")"
[[ "$loaded" == "$roundtrip" ]] || fail "first-equals state round-trip: $(quote_arg "$loaded")"
pass 'strict state round-trip and permissions'

for contents in '' 'OTHER=model-a' $'MODEL=model-a\nMODEL=model-b' $'MODEL=model-a\nTRAILING=x'; do
  printf '%s' "$contents" > "$state"
  if source_codex codex_load_model "$state" >/dev/null 2>&1; then
    fail "malformed state accepted: $(quote_arg "$contents")"
  fi
done
rm -f "$state"
source_codex codex_load_model "$state" >/dev/null 2>&1 && fail 'missing state accepted'
for invalid in $'provider/model\nother' $'provider/model\rother'; do
  source_codex codex_validate_model '{"data":[{"id":"provider/model"}]}' "$invalid" >/dev/null 2>&1 &&
    fail 'newline or carriage-return model accepted'
  source_codex codex_save_model "$state" "$invalid" >/dev/null 2>&1 &&
    fail 'newline or carriage-return model persisted'
done
printf 'MODEL=bad\0model\n' > "$state"
source_codex codex_load_model "$state" >/dev/null 2>&1 &&
  fail 'persisted model containing raw NUL accepted after Bash truncation'
pass 'missing malformed duplicate and control-byte state rejected'

ordinary_catalog='{"data":[{"id":"provider/name.with:dash_under score=high=exact"}]}'
source_codex codex_validate_model "$ordinary_catalog" "$roundtrip" || fail 'ordinary exact catalog ID rejected'
source_codex codex_validate_model "$ordinary_catalog" 'provider/missing' >/dev/null 2>&1 && fail 'stale model accepted'
source_codex janus_catalog_validate_json '{"data":[{"id":"bad\u0000model"}]}' >/dev/null 2>&1 &&
  fail 'escaped NUL catalog model accepted at JSON boundary'
pass 'catalog validation and escaped NUL rejection'

# A valid caller model wins over malformed/stale persisted state and does not
# rewrite it. It is still required to exist in the fetched catalog.
printf 'MODEL=stale/model\nMODEL=duplicate/model\n' > "$TMP/config/codex.conf"
before="$(sha256sum "$TMP/config/codex.conf")"
out="$(run_with_url 'https://janus.test' --model model-a exec prompt)"
after="$(sha256sum "$TMP/config/codex.conf")"
[[ "$before" == "$after" ]] || fail 'caller model rewrote stale persisted state'
assert_contains "$out" 'ARG[10]=--model' 'caller model retained'
expect_failure 'unknown caller model' 'is not available in the Janus catalog' --model missing/model
pass 'caller precedence without state rewrite and catalog validation'

# Missing, malformed, and stale state fail promptly with stdin unavailable.
for contents in missing 'OTHER=model-a' 'MODEL=stale/model'; do
  if [[ "$contents" == missing ]]; then rm -f "$TMP/config/codex.conf"; else printf '%s\n' "$contents" > "$TMP/config/codex.conf"; fi
  set +e
  output="$(env "${BASE_ENV[@]}" JANUS_LAUNCHER_BASE_URL=https://janus.test "$WRAPPER" </dev/null 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "noninteractive $contents state must fail without waiting for stdin"
  assert_contains "$output" 'codex-janus --model MODEL' "noninteractive $contents corrective command"
done
pass 'noninteractive missing and stale state fail without stdin'

# Only exact top-level informational requests bypass all Janus configuration and
# network activity. The full argument vector still reaches the resolved child.
passthrough_curl_log="$TMP/passthrough-curl.log"
printf '%s\n' 'not a configuration directory' > "$TMP/config-is-a-file"
for label in short-help long-help short-version long-version help-subcommand immediate-help; do
  case "$label" in
    short-help) args=(-h) ;;
    long-help) args=(--help) ;;
    short-version) args=(-V) ;;
    long-version) args=(--version) ;;
    help-subcommand) args=(help --verbose) ;;
    immediate-help) args=(--help -c 'model_provider="other"') ;;
  esac
  rm -f "$passthrough_curl_log"
  out="$(env PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/no-home-$label" \
    JANUS_LAUNCHER_CONFIG_DIR="$TMP/config-is-a-file" \
    JANUS_TEST_CURL_LOG="$passthrough_curl_log" EXPECTED_CODEX_KEY="$SECRET" \
    "$WRAPPER" "${args[@]}" 2>&1)"
  assert_contains "$out" "COUNT=${#args[@]}" "$label argument count"
  for i in "${!args[@]}"; do
    assert_contains "$out" "ARG[$i]=$(quote_arg "${args[$i]}")" "$label preserves argument $i"
  done
  assert_contains "$out" 'KEY_SET=no KEY_MATCH=no' "$label has no Janus key"
  [[ ! -s "$passthrough_curl_log" ]] || fail "$label must not invoke curl"
done
pass 'exact top-level passthrough bypasses Janus flow'

# The same spelling below a non-help subcommand is not a top-level bypass.
printf 'MODEL=model-a\n' > "$TMP/config/codex.conf"
curl_log="$TMP/curl.log"
rm -f "$curl_log"
out="$(env "${BASE_ENV[@]}" JANUS_LAUNCHER_BASE_URL=https://janus.test \
  JANUS_TEST_CURL_LOG="$curl_log" "$WRAPPER" exec --help 2>&1)"
assert_contains "$out" 'ARG[0]=-c' 'exec --help takes provider flow'
assert_contains "$out" 'ARG[10]=--model' 'exec --help gets selected model'
assert_contains "$out" 'ARG[12]=exec' 'exec --help subcommand preserved'
assert_contains "$out" 'ARG[13]=--help' 'exec --help option preserved'
assert_eq "$(<"$curl_log")" $'https://janus.test/v1/health\nhttps://janus.test/v1/models' \
  'Janus flow must contact health then models exactly once'
! grep -q '/responses' "$curl_log" || fail 'launcher must not probe the Responses generation endpoint'
pass 'full Janus flow ordering and non-generation probes'

# The real client is resolved before either bypass or Janus setup.
missing_path="$TMP/missing-bin"
mkdir -p "$missing_path"
set +e
missing_out="$(env PATH="$missing_path:/usr/bin:/bin" HOME="$TMP/missing-home" \
  JANUS_LAUNCHER_CONFIG_DIR="$TMP/missing-config" "$WRAPPER" --help 2>&1)"
missing_rc=$?
set -e
[[ $missing_rc -eq 127 ]] || fail "absent Codex must return 127, got $missing_rc"
assert_contains "$missing_out" 'Codex binary not found' 'absent Codex diagnostic'
pass 'Codex executable resolution precedes launch flow'

# Real launches use exec: the child's status and stderr arrive unchanged.
set +e
child_out="$(env "${BASE_ENV[@]}" JANUS_LAUNCHER_BASE_URL=https://janus.test \
  CODEX_TEST_STATUS=37 CODEX_TEST_STDERR='codex endpoint diagnostic marker' \
  "$WRAPPER" exec prompt 2>&1)"
child_rc=$?
set -e
[[ $child_rc -eq 37 ]] || fail "Codex child status must propagate, got $child_rc"
assert_contains "$child_out" 'codex endpoint diagnostic marker' 'Codex endpoint diagnostic passthrough'
pass 'child status and stderr propagate unchanged'

# Launch configuration is temporary. Preserve the user's Codex config, avoid
# profiles, preserve unrelated environment, and expose the secret under only
# the custom provider's configured key.
user_codex_config="$TMP/home/.codex/config.toml"
mkdir -p "$(dirname -- "$user_codex_config")"
printf '%s\n' 'model = "ordinary-user-model"' '[profiles.personal]' > "$user_codex_config"
config_before="$(sha256sum "$user_codex_config")"
out="$(env "${BASE_ENV[@]}" JANUS_LAUNCHER_BASE_URL=https://janus.test \
  UNRELATED_ENV=keep-me OPENAI_API_KEY=ordinary-openai-value "$WRAPPER" exec prompt 2>&1)"
config_after="$(sha256sum "$user_codex_config")"
[[ "$config_before" == "$config_after" ]] || fail '~/.codex/config.toml must remain untouched'
assert_not_contains "$out" '--profile' 'launcher must not generate a Codex profile'
assert_contains "$out" 'UNRELATED_ENV=keep-me' 'unrelated environment preserved'
assert_contains "$out" 'OPENAI_API_KEY=ordinary-openai-value' 'unrelated OpenAI environment preserved'
assert_contains "$out" 'SECRET_ENV_NAMES=EXPECTED_CODEX_KEY,JANUS_LAUNCHER_API_KEY,JANUS_LAUNCHER_CODEX_API_KEY' 'custom provider key is the only new secret environment name'
pass 'temporary provider leaves user Codex state and unrelated environment untouched'

# Dry runs contain the exact array construction and a set marker, but neither
# invoke Codex nor reveal the secret value.
dry_curl_log="$TMP/dry-curl.log"
rm -f "$dry_curl_log"
out="$(env "${BASE_ENV[@]}" JANUS_LAUNCHER_BASE_URL=https://janus.test \
  JANUS_TEST_CURL_LOG="$dry_curl_log" JANUS_LAUNCHER_DRY_RUN=1 \
  CODEX_TEST_STDERR='must not execute child' "$WRAPPER" exec 'prompt text' 2>&1)"
assert_contains "$out" '[dry-run] would exec:' 'dry-run command marker'
assert_contains "$out" 'JANUS_LAUNCHER_CODEX_API_KEY=<set>' 'dry-run key marker'
assert_contains "$out" 'model_provider=\"janus\"' 'dry-run provider selection'
assert_contains "$out" 'exec prompt\ text' 'dry-run caller ordering'
assert_not_contains "$out" "$SECRET" 'dry-run secret redaction'
assert_not_contains "$out" 'must not execute child' 'dry-run skips child execution'
[[ "$(wc -l < "$dry_curl_log")" -eq 2 ]] || fail 'dry-run must still perform health and one catalog fetch'
pass 'dry-run redacts secret and does not execute Codex'

printf 'All Codex launcher Task 7 shell tests passed.\n'
