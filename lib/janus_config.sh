#!/usr/bin/env bash
# Shared configuration helpers for Janus Launcher.
# Safe to source; no side effects at load time.

if [[ -n "${JANUS_CONFIG_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
JANUS_CONFIG_SH_LOADED=1

janus_config_init_paths() {
  JANUS_CONFIG_DIR="${JANUS_LAUNCHER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/janus-launcher}"
  JANUS_ROUTER_CONFIG="$JANUS_CONFIG_DIR/router.conf"
  JANUS_CLAUDE_MAPPINGS="$JANUS_CONFIG_DIR/claude-mappings.conf"
  JANUS_CODEX_CONFIG="$JANUS_CONFIG_DIR/codex.conf"
}

janus_config_load_router() {
  local file="$1" line value
  local file_base="" file_key=""
  local saw_base=0 saw_key=0 line_number=0

  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      ((line_number += 1))
      case "$line" in
        ''|'#'*) continue ;;
        JANUS_BASE_URL=*)
          if ((saw_base)); then
            printf 'Janus Launcher: duplicate JANUS_BASE_URL in %s at line %d.\n' \
              "$file" "$line_number" >&2
            return 1
          fi
          saw_base=1
          value="${line#JANUS_BASE_URL=}"
          file_base="$value"
          ;;
        JANUS_API_KEY=*)
          if ((saw_key)); then
            printf 'Janus Launcher: duplicate JANUS_API_KEY in %s at line %d.\n' \
              "$file" "$line_number" >&2
            return 1
          fi
          saw_key=1
          value="${line#JANUS_API_KEY=}"
          file_key="$value"
          ;;
        *)
          printf 'Janus Launcher: invalid router configuration in %s at line %d.\n' \
            "$file" "$line_number" >&2
          return 1
          ;;
      esac
    done < "$file"
  elif [[ -e "$file" ]]; then
    printf 'Janus Launcher: router configuration is not a regular file: %s\n' "$file" >&2
    return 1
  fi

  JANUS_BASE_URL="${JANUS_LAUNCHER_BASE_URL:-$file_base}"
  JANUS_API_KEY="${JANUS_LAUNCHER_API_KEY:-$file_key}"
  if [[ -n "$JANUS_BASE_URL" ]]; then
    JANUS_BASE_URL="$(janus_normalize_base_url "$JANUS_BASE_URL")"
  fi
}

janus_config_is_placeholder() {
  local base_url="$1" api_key="$2"
  [[ -z "$base_url" || -z "$api_key" ||
    "$base_url" == *'your-janus-router.example'* ||
    "$api_key" == 'replace-with-your-key' ]]
}

janus_config_write_router() {
  local file="$1" base_url="$2" api_key="$3"
  local directory temporary
  directory="$(dirname -- "$file")"
  base_url="$(janus_normalize_base_url "$base_url")"

  if ! mkdir -p -- "$directory" || ! chmod 700 -- "$directory"; then
    printf 'Janus Launcher: cannot secure configuration directory: %s\n' "$directory" >&2
    return 1
  fi
  if [[ -d "$file" ]]; then
    printf 'Janus Launcher: router configuration path is a directory: %s\n' "$file" >&2
    return 1
  fi
  temporary="$(mktemp "$directory/.router.conf.XXXXXX")" || {
    printf 'Janus Launcher: cannot create router configuration in %s.\n' "$directory" >&2
    return 1
  }
  if ! chmod 600 -- "$temporary" ||
    ! printf 'JANUS_BASE_URL=%s\nJANUS_API_KEY=%s\n' "$base_url" "$api_key" > "$temporary" ||
    ! mv -fT -- "$temporary" "$file" ||
    [[ ! -f "$file" ]]; then
    rm -f -- "$temporary"
    printf 'Janus Launcher: cannot write router configuration: %s\n' "$file" >&2
    return 1
  fi
}

janus_config_run_first_setup() {
  local base_url api_key

  if [[ -n "${JANUS_LAUNCHER_SETUP_BASE_URL:-}" &&
    -n "${JANUS_LAUNCHER_SETUP_API_KEY:-}" ]]; then
    base_url="$JANUS_LAUNCHER_SETUP_BASE_URL"
    api_key="$JANUS_LAUNCHER_SETUP_API_KEY"
  else
    if [[ ! -t 0 || ! -t 2 ]]; then
      printf 'Janus Launcher: router configuration is missing or uses placeholders.\n' >&2
      printf 'Create %s or set JANUS_LAUNCHER_BASE_URL and JANUS_LAUNCHER_API_KEY.\n' \
        "$JANUS_ROUTER_CONFIG" >&2
      return 2
    fi
    printf 'Janus base URL (no /v1 required): ' >&2
    IFS= read -r base_url || base_url=""
    printf 'Janus API key: ' >&2
    IFS= read -r api_key || api_key=""
    if [[ -z "$base_url" || -z "$api_key" ]]; then
      printf 'Janus Launcher: setup cancelled (empty URL or key).\n' >&2
      return 2
    fi
  fi

  janus_config_write_router "$JANUS_ROUTER_CONFIG" "$base_url" "$api_key" || return
  JANUS_BASE_URL="$(janus_normalize_base_url "$base_url")"
  JANUS_API_KEY="$api_key"
}
