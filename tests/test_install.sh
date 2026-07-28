#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$1"; }
mode() { stat -c '%a' "$1"; }
assert_mode() { [[ "$(mode "$1")" == "$2" ]] || fail "$1 mode: expected $2, got $(mode "$1")"; }

run_install() {
  local case_dir="$1"
  HOME="$case_dir/home" \
  XDG_CONFIG_HOME="$case_dir/config" \
  XDG_DATA_HOME="$case_dir/data" \
  JANUS_LAUNCHER_INSTALL_DIR="$case_dir/commands" \
  PATH="/usr/bin:/bin" \
  "$ROOT/install.sh"
}

fresh="$TMP/fresh"
mkdir -p "$fresh/home"
output="$(run_install "$fresh")"
for command in janus-launcher claude-janus codex-janus; do
  [[ -f "$fresh/commands/$command" ]] || fail "missing installed command $command"
  assert_mode "$fresh/commands/$command" 755
done
for library in janus_api.sh janus_config.sh janus_runtime.sh janus_ui.sh; do
  [[ -f "$fresh/data/janus-launcher/lib/$library" ]] || fail "missing installed library $library"
  assert_mode "$fresh/data/janus-launcher/lib/$library" 644
done
assert_mode "$fresh/config/janus-launcher" 700
assert_mode "$fresh/config/janus-launcher/router.conf" 600
[[ "$output" == *'Installed janus-launcher'* && "$output" == *'Installed claude-janus'* && "$output" == *'Installed codex-janus'* && "$output" == *'PATH'* ]] || fail 'new identity install output'
pass 'fresh layout, modes, and output'

before="$(sha256sum "$fresh/config/janus-launcher/router.conf")"
run_install "$fresh" >/dev/null
after="$(sha256sum "$fresh/config/janus-launcher/router.conf")"
[[ "$before" == "$after" ]] || fail 'idempotent install rewrote router config'
pass 'idempotent installation preserves router config'

valid="$TMP/valid"
mkdir -p "$valid/home" "$valid/config/janus-launcher"
printf 'JANUS_BASE_URL=https://kept.example/v1\nJANUS_API_KEY=keep-secret\n' > "$valid/config/janus-launcher/router.conf"
chmod 644 "$valid/config/janus-launcher/router.conf"
run_install "$valid" >/dev/null
[[ "$(<"$valid/config/janus-launcher/router.conf")" == $'JANUS_BASE_URL=https://kept.example/v1\nJANUS_API_KEY=keep-secret' ]] || fail 'valid config changed'
assert_mode "$valid/config/janus-launcher/router.conf" 600
pass 'valid existing config is preserved and secured'

malformed="$TMP/malformed"
mkdir -p "$malformed/home" "$malformed/config/janus-launcher"
printf 'JANUS_BASE_URL=https://router.example\nBOGUS=value\n' > "$malformed/config/janus-launcher/router.conf"
set +e
output="$(run_install "$malformed" 2>&1)"; status=$?
set -e
[[ $status -ne 0 && "$output" == *'invalid router configuration'* ]] || fail 'malformed existing config not rejected actionably'
[[ "$(<"$malformed/config/janus-launcher/router.conf")" == $'JANUS_BASE_URL=https://router.example\nBOGUS=value' ]] || fail 'malformed config was overwritten'
pass 'malformed existing config is rejected without overwrite'

legacy="$TMP/legacy"
mkdir -p "$legacy/home/.config/claude-janus" "$legacy/home"
printf 'legacy sentinel\n' > "$legacy/home/.config/claude-janus/router.conf"
run_install "$legacy" >/dev/null
[[ "$(<"$legacy/home/.config/claude-janus/router.conf")" == 'legacy sentinel' ]] || fail 'legacy config touched'
[[ -f "$legacy/config/janus-launcher/router.conf" ]] || fail 'new config not seeded beside legacy config'
pass 'legacy config remains untouched during clean break'

noclients="$TMP/no-clients"
mkdir -p "$noclients/home"
PATH="/usr/bin:/bin" run_install "$noclients" >/dev/null
pass 'installation does not require client executables'

unwritable="$TMP/unwritable"
mkdir -p "$unwritable/home" "$unwritable/config" "$unwritable/data"
printf 'occupied\n' > "$unwritable/commands"
set +e
output="$(run_install "$unwritable" 2>&1)"; status=$?
set -e
[[ $status -ne 0 && "$output" == *'cannot create installation directory'* ]] || fail 'unwritable/invalid destination lacks actionable failure'
pass 'invalid installation destination fails actionably'

printf 'All installer tests passed.\n'
