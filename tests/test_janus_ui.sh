#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# The UI module is intentionally sourced before it exists during RED.
source "$ROOT/lib/janus_ui.sh"

JANUS_UI_DISABLE=1 NO_COLOR=1 janus_ui_init 'CLAUDE CODE · OFFICIAL JANUS COMPANION'
! janus_ui_is_interactive || fail "disabled UI detected as interactive"
[[ -z "$RESET$BOLD$DIM$CYAN$BLUE$GREEN$YELLOW$RED$MAGENTA" ]] ||
  fail "colors enabled with NO_COLOR"
header="$(janus_ui_header 'Test title' 'Test subtitle' 2>&1)"
[[ "$header" == *'CLAUDE CODE · OFFICIAL JANUS COMPANION'* && "$header" == *'Test title'* && "$header" == *'Test subtitle'* ]] ||
  fail "text header missing content"
[[ "$header" != *$'\033['* ]] || fail "text header emitted escapes"
header_first="${header%%$'\n'*}"
header_last="${header##*$'\n'}"
assert_eq "${#header_first}" "${#header_last}" \
  "header border alignment"
assert_eq "${#header_first}" 68 "Claude header width"
pass "noninteractive text-only UI"

janus_ui_read_key < <(printf '\n')
assert_eq "$JANUS_UI_KEY" enter "Enter decoding"
janus_ui_read_key < <(printf '\033[A')
assert_eq "$JANUS_UI_KEY" up "up-arrow decoding"
janus_ui_read_key < <(printf '\033[B')
assert_eq "$JANUS_UI_KEY" down "down-arrow decoding"
janus_ui_read_key < <(printf 'q')
assert_eq "$JANUS_UI_KEY" q "literal key decoding"
pass "key decoding"

JANUS_UI_TTY_ORIGINAL=original
JANUS_UI_TTY_RAW=1
stty_calls=0
stty() { ((stty_calls += 1)); return 0; }
janus_ui_tty_restore
janus_ui_tty_restore
assert_eq "$stty_calls" 1 "terminal restore count"
assert_eq "$JANUS_UI_TTY_RAW" 0 "terminal raw state"
pass "idempotent terminal restoration"

printf 'All janus_ui unit tests passed.\n'
