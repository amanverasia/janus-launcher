#!/usr/bin/env bash
# Shared terminal primitives for Janus Launcher.
# Safe to source; call janus_ui_init before rendering.

if [[ -n "${JANUS_UI_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
JANUS_UI_SH_LOADED=1

JANUS_UI_ENABLED=0
JANUS_UI_PRODUCT='JANUS LAUNCHER'
JANUS_UI_TTY_ORIGINAL=''
JANUS_UI_TTY_RAW=0
JANUS_UI_KEY=''
JANUS_UI_RESULT=''
JANUS_UI_REDRAW_IN_PLACE=0

janus_ui_init() {
  JANUS_UI_PRODUCT="${1:-JANUS LAUNCHER}"
  JANUS_UI_ENABLED=0
  if [[ -t 0 && -t 2 && -z "${JANUS_UI_DISABLE:-}" ]]; then
    JANUS_UI_ENABLED=1
  fi

  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
    CYAN=$'\033[36m'; BLUE=$'\033[34m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'
  else
    RESET=''; BOLD=''; DIM=''; CYAN=''; BLUE=''; GREEN=''
    YELLOW=''; RED=''; MAGENTA=''
  fi

  JANUS_UI_TTY_ORIGINAL=''
  JANUS_UI_TTY_RAW=0
  if [[ $JANUS_UI_ENABLED -eq 1 ]]; then
    JANUS_UI_TTY_ORIGINAL="$(stty -g 2>/dev/null || true)"
  fi

  trap 'janus_ui_tty_restore' EXIT
  trap 'janus_ui_tty_restore; exit 130' INT
  trap 'janus_ui_tty_restore; exit 143' TERM HUP
}

janus_ui_is_interactive() {
  [[ $JANUS_UI_ENABLED -eq 1 ]]
}

janus_ui_read_reply() {
  local answer=''
  if [[ -t 0 ]]; then
    IFS= read -er answer || answer=''
  elif { exec 3</dev/tty; } 2>/dev/null; then
    IFS= read -er answer <&3 || answer=''
    exec 3<&- 2>/dev/null || true
  else
    IFS= read -r answer || answer=''
  fi
  printf '%s' "$answer"
}

janus_ui_tty_raw() {
  [[ $JANUS_UI_ENABLED -eq 1 && $JANUS_UI_TTY_RAW -eq 0 && -n "$JANUS_UI_TTY_ORIGINAL" ]] || return 0
  stty -echo -icanon min 1 time 0 2>/dev/null || return 0
  JANUS_UI_TTY_RAW=1
}

janus_ui_tty_restore() {
  [[ $JANUS_UI_TTY_RAW -eq 1 && -n "$JANUS_UI_TTY_ORIGINAL" ]] || return 0
  stty "$JANUS_UI_TTY_ORIGINAL" 2>/dev/null || true
  JANUS_UI_TTY_RAW=0
}

janus_ui_read_key() {
  local key='' suffix=''
  JANUS_UI_KEY=''
  if ! IFS= read -rsn1 key; then
    JANUS_UI_KEY='esc'
    return 0
  fi
  case "$key" in
    '') JANUS_UI_KEY='enter' ;;
    $'\033')
      IFS= read -rsn2 -t 0.12 suffix || true
      case "$suffix" in
        '[A'|'OA') JANUS_UI_KEY='up' ;;
        '[B'|'OB') JANUS_UI_KEY='down' ;;
        '[C'|'OC') JANUS_UI_KEY='right' ;;
        '[D'|'OD') JANUS_UI_KEY='left' ;;
        '[H'|'OH') JANUS_UI_KEY='home' ;;
        '[F'|'OF') JANUS_UI_KEY='end' ;;
        *) JANUS_UI_KEY='esc' ;;
      esac
      ;;
    *) JANUS_UI_KEY="$key" ;;
  esac
}

janus_ui_navigate() {
  local count="$1" cursor="$2" renderer="$3" shortcuts="$4"
  local i pressed
  shift 4
  JANUS_UI_RESULT=''
  JANUS_UI_REDRAW_IN_PLACE=0
  janus_ui_tty_raw
  while true; do
    "$renderer" "$cursor" "$@"
    janus_ui_read_key
    case "$JANUS_UI_KEY" in
      up)   (( cursor = cursor <= 1 ? count : cursor - 1 )); JANUS_UI_REDRAW_IN_PLACE=1 ;;
      down) (( cursor = cursor >= count ? 1 : cursor + 1 )); JANUS_UI_REDRAW_IN_PLACE=1 ;;
      home) cursor=1; JANUS_UI_REDRAW_IN_PLACE=1 ;;
      end)  cursor="$count"; JANUS_UI_REDRAW_IN_PLACE=1 ;;
      left|right) ;;
      enter)
        JANUS_UI_RESULT="$cursor"
        janus_ui_tty_restore
        JANUS_UI_REDRAW_IN_PLACE=0
        return 0
        ;;
      esc|q|Q|b|B)
        JANUS_UI_RESULT='back'
        janus_ui_tty_restore
        JANUS_UI_REDRAW_IN_PLACE=0
        return 0
        ;;
      [1-9])
        if (( 10#$JANUS_UI_KEY <= count )); then
          JANUS_UI_RESULT="$JANUS_UI_KEY"
          janus_ui_tty_restore
          JANUS_UI_REDRAW_IN_PLACE=0
          return 0
        fi
        printf '\a' >&2
        ;;
      *)
        pressed="${JANUS_UI_KEY,,}"
        for ((i=0; i<${#shortcuts}; i++)); do
          if [[ "$pressed" == "${shortcuts:i:1}" ]]; then
            JANUS_UI_RESULT="$((i + 1))"
            janus_ui_tty_restore
            JANUS_UI_REDRAW_IN_PLACE=0
            return 0
          fi
        done
        printf '\a' >&2
        ;;
    esac
  done
}

janus_ui_clear() {
  janus_ui_is_interactive || return 0
  printf '\033[2J\033[H' >&2
}

janus_ui_prepare_screen() {
  janus_ui_is_interactive || return 0
  if [[ ${JANUS_UI_REDRAW_IN_PLACE:-0} -eq 1 ]]; then
    printf '\033[H' >&2
  else
    janus_ui_clear
  fi
}

janus_ui_header() {
  local title="$1" subtitle="${2:-}"
  janus_ui_prepare_screen
  printf '%s╭─ %s ─────────────────────────────────────────────────────────────%s\n' \
    "$CYAN" "$JANUS_UI_PRODUCT" "$RESET" >&2
  printf '│ %s%s%s\n' "$BOLD" "$title" "$RESET" >&2
  [[ -z "$subtitle" ]] || printf '│ %s%s%s\n' "$DIM" "$subtitle" "$RESET" >&2
  printf '%s╰───────────────────────────────────────────────────────────────────%s\n\n' "$CYAN" "$RESET" >&2
}

janus_ui_pause() {
  janus_ui_is_interactive || return 0
  janus_ui_tty_raw
  printf '\n%sPress any key to continue…%s ' "$DIM" "$RESET" >&2
  janus_ui_read_key
  janus_ui_tty_restore
}

janus_ui_message() {
  local kind="$1" title="$2" message="$3" color icon
  case "$kind" in
    success) color="$GREEN"; icon='✓' ;;
    warning) color="$YELLOW"; icon='!' ;;
    error) color="$RED"; icon='×' ;;
    *) color="$CYAN"; icon='•' ;;
  esac
  if janus_ui_is_interactive; then
    janus_ui_tty_raw
    janus_ui_header "$title"
    printf '  %s%s%s  %s\n' "$color$BOLD" "$icon" "$RESET" "$message" >&2
    janus_ui_pause
  else
    printf '%s%s:%s %s\n' "$color$BOLD" "$title" "$RESET" "$message" >&2
  fi
}

janus_ui_choice() {
  local cursor="$1" index="$2" shortcut="$3" label="$4" suffix="${5:-}"
  local marker=' '
  if (( cursor == index )); then
    marker="${CYAN}${BOLD}❯${RESET}"
    printf '  %s  %s[%s]%s  %s%s%s' \
      "$marker" "$CYAN$BOLD" "$shortcut" "$RESET" "$BOLD" "$label" "$RESET" >&2
  else
    printf '     %s[%s]%s  %s' "$DIM" "$shortcut" "$RESET" "$label" >&2
  fi
  [[ -z "$suffix" ]] || printf '  %s' "$suffix" >&2
  printf '\n' >&2
}
