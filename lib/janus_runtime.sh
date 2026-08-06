#!/usr/bin/env bash
# Shared launcher runtime helpers for Janus Launcher.
# Safe to source; no side effects at load time.

if [[ -n "${JANUS_RUNTIME_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
JANUS_RUNTIME_SH_LOADED=1

janus_require_command() {
  local command_name="$1" label="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Janus Launcher: %s requires %s (%s).\n' \
      "$label" "$command_name" "$command_name" >&2
    return 127
  fi
}

janus_require_shared_dependencies() {
  janus_require_command curl 'service validation' || return
  janus_require_command jq 'catalog processing' || return
}

janus_resolve_client_executable() {
  local name="$1" wrapper_path="$2" path_entry candidate
  local wrapper_real candidate_real

  wrapper_real="$(janus_realpath "$wrapper_path")"
  while IFS= read -r path_entry; do
    [[ -n "$path_entry" ]] || path_entry='.'
    candidate="$path_entry/$name"
    [[ -x "$candidate" && ! -d "$candidate" ]] || continue
    candidate_real="$(janus_realpath "$candidate")"
    [[ "$candidate_real" == "$wrapper_real" ]] && continue
    printf '%s\n' "$candidate"
    return 0
  done < <(printf '%s' "${PATH:-}" | tr ':' '\n')
  return 127
}

janus_realpath() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null && return 0
  fi
  readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
}

janus_is_top_level_passthrough() {
  case "${1-}" in
    -h|--help|-V|--version|help) return 0 ;;
    *) return 1 ;;
  esac
}

janus_load_validated_service() {
  local validation_output validation_status

  janus_config_init_paths || return
  janus_config_load_router "$JANUS_ROUTER_CONFIG" || return
  if janus_config_is_placeholder "$JANUS_BASE_URL" "$JANUS_API_KEY"; then
    janus_config_run_first_setup || return
  fi
  JANUS_BASE_URL="$(janus_normalize_base_url "$JANUS_BASE_URL")"
  if validation_output="$(janus_validate_service "$JANUS_BASE_URL" "$JANUS_API_KEY")"; then
    JANUS_CATALOG_JSON="$validation_output"
    return 0
  else
    validation_status=$?
  fi
  case "$validation_status" in
    1) printf 'Janus Launcher: Janus health check failed.\n' >&2 ;;
    2) printf 'Janus Launcher: Janus model catalog request failed.\n' >&2 ;;
    3) printf 'Janus Launcher: Janus model catalog response was malformed.\n' >&2 ;;
    4) printf 'Janus Launcher: Janus model catalog is empty.\n' >&2 ;;
  esac
  return "$validation_status"
}
