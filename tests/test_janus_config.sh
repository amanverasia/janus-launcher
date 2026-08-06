#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}
mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME="$TMP/home" XDG_CONFIG_HOME= JANUS_LAUNCHER_CONFIG_DIR= bash -c '
  source lib/janus_api.sh
  source lib/janus_config.sh
  janus_config_init_paths
  [[ "$JANUS_CONFIG_DIR" == "$HOME/.config/janus-launcher" ]]
' || fail "default configuration paths"

XDG_CONFIG_HOME="$TMP/xdg" JANUS_LAUNCHER_CONFIG_DIR= bash -c '
  source lib/janus_api.sh
  source lib/janus_config.sh
  janus_config_init_paths
  [[ "$JANUS_CONFIG_DIR" == "'$TMP'/xdg/janus-launcher" ]]
' || fail "XDG configuration path"

JANUS_LAUNCHER_CONFIG_DIR="$TMP/custom" bash -c '
  source lib/janus_api.sh
  source lib/janus_config.sh
  janus_config_init_paths
  [[ "$JANUS_ROUTER_CONFIG" == "'$TMP'/custom/router.conf" ]]
  [[ "$JANUS_CLAUDE_MAPPINGS" == "'$TMP'/custom/claude-mappings.conf" ]]
  [[ "$JANUS_CODEX_CONFIG" == "'$TMP'/custom/codex.conf" ]]
' || fail "custom configuration paths"
pass "clean-break configuration paths"

cat > "$TMP/router.conf" <<'EOF'
# shared credentials
JANUS_BASE_URL=https://file.janus.test/v1/
JANUS_API_KEY=file-secret
EOF
JANUS_LAUNCHER_BASE_URL='https://override.janus.test/' \
  JANUS_LAUNCHER_API_KEY= ROUTER="$TMP/router.conf" bash -c '
    source lib/janus_api.sh
    source lib/janus_config.sh
    janus_config_load_router "$ROUTER"
    [[ "$JANUS_BASE_URL" == "https://override.janus.test" ]]
    [[ "$JANUS_API_KEY" == "file-secret" ]]
  ' || fail "partial launcher environment precedence"

JANUS_LAUNCHER_BASE_URL= JANUS_LAUNCHER_API_KEY='override-secret' \
  ROUTER="$TMP/router.conf" bash -c '
    source lib/janus_api.sh
    source lib/janus_config.sh
    janus_config_load_router "$ROUTER"
    [[ "$JANUS_BASE_URL" == "https://file.janus.test" ]]
    [[ "$JANUS_API_KEY" == "override-secret" ]]
  ' || fail "API key launcher environment precedence"
pass "router parsing and partial precedence"

mkdir -p "$TMP/legacy-home/.config/claude-janus"
printf 'JANUS_BASE_URL=https://legacy-file.test\nJANUS_API_KEY=legacy-file-secret\n' \
  > "$TMP/legacy-home/.config/claude-janus/router.conf"
HOME="$TMP/legacy-home" CLAUDE_JANUS_CONFIG="$TMP/router.conf" \
  JANUS_BASE_URL='https://legacy-env.test' JANUS_API_KEY='legacy-env-secret' \
  JANUS_LAUNCHER_BASE_URL= JANUS_LAUNCHER_API_KEY= bash -c '
    source lib/janus_api.sh
    source lib/janus_config.sh
    janus_config_init_paths
    janus_config_load_router "$JANUS_ROUTER_CONFIG"
    [[ "$JANUS_CONFIG_DIR" == "$HOME/.config/janus-launcher" ]]
    [[ -z "$JANUS_BASE_URL" ]]
    [[ -z "$JANUS_API_KEY" ]]
  ' || fail "legacy configuration isolation"
pass "legacy files and overrides ignored"

for contents in \
  'UNKNOWN=value' \
  'JANUS_BASE_URL=https://one.test
JANUS_BASE_URL=https://two.test' \
  'JANUS_API_KEY=one
JANUS_API_KEY=two' \
  'JANUS_BASE_URL https://malformed.test'
do
  printf '%s\n' "$contents" > "$TMP/invalid.conf"
  if ROUTER="$TMP/invalid.conf" bash -c '
    source lib/janus_api.sh
    source lib/janus_config.sh
    janus_config_load_router "$ROUTER"
  ' >"$TMP/invalid.out" 2>"$TMP/invalid.err"; then
    fail "malformed or duplicate router line accepted"
  fi
done

secret='do-not-print-this-secret'
printf 'JANUS_API_KEY=%s\nUNKNOWN=value\n' "$secret" > "$TMP/redaction.conf"
if ROUTER="$TMP/redaction.conf" bash -c '
  source lib/janus_api.sh
  source lib/janus_config.sh
  janus_config_load_router "$ROUTER"
' >"$TMP/redaction.out" 2>"$TMP/redaction.err"; then
  fail "invalid router accepted during redaction test"
fi
! grep -F "$secret" "$TMP/redaction.out" "$TMP/redaction.err" >/dev/null \
  || fail "router diagnostic leaked API key"
pass "strict parser and redacted errors"

source "$ROOT/lib/janus_api.sh"
source "$ROOT/lib/janus_config.sh"
janus_config_is_placeholder '' 'key' || fail "missing base URL placeholder"
janus_config_is_placeholder 'https://janus.test' '' || fail "missing API key placeholder"
janus_config_is_placeholder 'https://your-janus-router.example' 'key' \
  || fail "example base URL placeholder"
janus_config_is_placeholder 'https://janus.test' 'replace-with-your-key' \
  || fail "example API key placeholder"
! janus_config_is_placeholder 'https://janus.test' 'real-key' \
  || fail "real credentials marked as placeholders"
pass "placeholder detection"

mkdir -p "$TMP/write/private"
chmod 755 "$TMP/write/private"
janus_config_write_router "$TMP/write/private/router.conf" \
  'https://write.janus.test/v1/' 'write-secret'
assert_eq "$(mode "$TMP/write/private")" '700' "router directory mode"
assert_eq "$(mode "$TMP/write/private/router.conf")" '600' "router file mode"
assert_eq "$(<"$TMP/write/private/router.conf")" \
  $'JANUS_BASE_URL=https://write.janus.test\nJANUS_API_KEY=write-secret' \
  "normalized router persistence"
if find "$TMP/write/private" -maxdepth 1 -type f ! -name router.conf | grep -q .; then
  fail "router temporary file left behind"
fi
pass "secure atomic router persistence"

printf 'stale router contents\n' > "$TMP/write/private/router.conf"
chmod 644 "$TMP/write/private/router.conf"
janus_config_write_router "$TMP/write/private/router.conf" \
  'https://replacement.janus.test/v1/' 'replacement-secret'
assert_eq "$(mode "$TMP/write/private/router.conf")" '600' \
  "replacement router file mode"
assert_eq "$(<"$TMP/write/private/router.conf")" \
  $'JANUS_BASE_URL=https://replacement.janus.test\nJANUS_API_KEY=replacement-secret' \
  "existing router replacement"
pass "existing router replaced securely"

mkdir -p "$TMP/directory-target/router.conf"
if janus_config_write_router "$TMP/directory-target/router.conf" \
  'https://rejected.janus.test' 'rejected-secret' \
  >"$TMP/directory-target.out" 2>"$TMP/directory-target.err"; then
  fail "router directory destination accepted"
fi
[[ -d "$TMP/directory-target/router.conf" ]] \
  || fail "router directory destination changed"
if find "$TMP/directory-target" -mindepth 1 \
  \( -type f -o -type l \) | grep -q .; then
  fail "directory destination left temporary files inside or beside target"
fi
pass "router directory destination rejected cleanly"

JANUS_LAUNCHER_CONFIG_DIR="$TMP/setup" janus_config_init_paths
JANUS_LAUNCHER_SETUP_BASE_URL='https://setup.janus.test/v1/' \
JANUS_LAUNCHER_SETUP_API_KEY='setup-secret' \
  janus_config_run_first_setup
assert_eq "$JANUS_BASE_URL" 'https://setup.janus.test' "first setup base URL"
assert_eq "$JANUS_API_KEY" 'setup-secret' "first setup API key"
assert_eq "$(<"$JANUS_ROUTER_CONFIG")" \
  $'JANUS_BASE_URL=https://setup.janus.test\nJANUS_API_KEY=setup-secret' \
  "first setup persistence"
pass "noninteractive first setup"

mkdir -p "$TMP/setup-failure/router.conf"
JANUS_ROUTER_CONFIG="$TMP/setup-failure/router.conf"
JANUS_BASE_URL='https://existing.janus.test'
JANUS_API_KEY='existing-secret'
if JANUS_LAUNCHER_SETUP_BASE_URL='https://failed-setup.janus.test/v1/' \
  JANUS_LAUNCHER_SETUP_API_KEY='failed-setup-secret' \
  janus_config_run_first_setup \
  >"$TMP/setup-failure.out" 2>"$TMP/setup-failure.err"; then
  fail "first setup succeeded when persistence failed"
fi
assert_eq "$JANUS_BASE_URL" 'https://existing.janus.test' \
  "first setup preserved existing base URL after persistence failure"
assert_eq "$JANUS_API_KEY" 'existing-secret' \
  "first setup preserved existing API key after persistence failure"
if find "$TMP/setup-failure" -mindepth 1 \
  \( -type f -o -type l \) | grep -q .; then
  fail "failed first setup left temporary files"
fi
pass "first setup preserves credentials on persistence failure"

printf 'All janus_config unit tests passed.\n'
