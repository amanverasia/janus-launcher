#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCHER="$ROOT/bin/janus-launcher"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS %s\n' "$1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }

mkdir -p "$TMP/sibling" "$TMP/path-bin" "$TMP/home"
cp "$DISPATCHER" "$TMP/sibling/janus-launcher" 2>/dev/null || true
make_fake() {
  local path="$1" label="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
printf 'CLIENT=%s\n' '$label'
printf 'ARGC=%d\n' "\$#"
i=0
for arg in "\$@"; do printf 'ARG[%d]=<%s>\n' "\$i" "\$arg"; ((i += 1)); done
exit "\${FAKE_STATUS:-0}"
EOF
  chmod +x "$path"
}
make_fake "$TMP/sibling/claude-janus" sibling-claude
make_fake "$TMP/sibling/codex-janus" sibling-codex
make_fake "$TMP/path-bin/claude-janus" path-claude
make_fake "$TMP/path-bin/codex-janus" path-codex

[[ -x "$DISPATCHER" ]] || fail 'dispatcher executable is missing'
cp "$DISPATCHER" "$TMP/sibling/janus-launcher"

output="$(PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" claude '' 'two words' '*' '"quoted"')"
expected=$'CLIENT=sibling-claude\nARGC=4\nARG[0]=<>\nARG[1]=<two words>\nARG[2]=<*>\nARG[3]=<"quoted">'
assert_eq "$output" "$expected" 'sibling Claude delegation and argv'
pass 'sibling Claude delegation preserves argv'

rm "$TMP/sibling/codex-janus"
output="$(PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" codex exec 'a b')"
assert_eq "$output" $'CLIENT=path-codex\nARGC=2\nARG[0]=<exec>\nARG[1]=<a b>' 'PATH Codex delegation'
pass 'installed PATH fallback preserves argv'

set +e
FAKE_STATUS=37 PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" claude >/dev/null
status=$?
set -e
assert_eq "$status" 37 'child exit propagation'
pass 'child exit status propagates'

set +e
output="$(PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" other 2>&1)"; status=$?
set -e
[[ $status -ne 0 ]] || fail 'unknown client must fail'
[[ "$output" == *'Unknown client: other'* && "$output" == *'Usage: janus-launcher {claude|codex} [arguments...]'* ]] || fail 'unknown-client diagnostics'
pass 'unknown client prints error and usage'

set +e
output="$(PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" </dev/null 2>&1)"; status=$?
set -e
[[ $status -ne 0 && "$output" == 'Usage: janus-launcher {claude|codex} [arguments...]' ]] || fail 'noninteractive no-client usage'
pass 'noninteractive no-client fails with usage'

rm -f "$TMP/sibling/claude-janus" "$TMP/path-bin/claude-janus"
set +e
output="$(PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" claude 2>&1)"; status=$?
set -e
assert_eq "$status" 127 'missing launcher status'
[[ "$output" == *'claude-janus not found'* ]] || fail 'missing launcher diagnostic'
pass 'missing dedicated launcher returns 127'

mkdir -p "$TMP/poison/lib"
printf 'exit 91\n' > "$TMP/poison/lib/janus_ui.sh"
make_fake "$TMP/path-bin/claude-janus" path-claude
output="$(HOME="$TMP/home" XDG_DATA_HOME="$TMP/poison" JANUS_LAUNCHER_CONFIG_DIR="$TMP/forbidden-config" PATH="$TMP/path-bin:/usr/bin:/bin" "$TMP/sibling/janus-launcher" claude safe)"
[[ "$output" == *'ARG[0]=<safe>'* && ! -e "$TMP/forbidden-config" ]] || fail 'explicit dispatcher touched UI/config/network path'
pass 'explicit dispatcher has no Janus config, UI, or network activity'

printf 'All dispatcher shell tests passed.\n'
