#!/usr/bin/env bash
# Shared Janus HTTP/catalog helpers for Janus Launcher.
# Safe to source; no side effects at load time.

janus_normalize_base_url() {
  local u="${1%/}"
  if [[ "$u" == */v1 ]]; then
    u="${u%/v1}"
  fi
  printf '%s' "$u"
}

janus_api_root() {
  printf '%s/v1\n' "$(janus_normalize_base_url "$1")"
}

janus_catalog_validate_json() {
  command -v jq >/dev/null 2>&1 || {
    printf 'Janus Launcher requires jq.\n' >&2
    return 127
  }
  jq -e 'type == "object" and (.data | type == "array") and all(.data[]; (.id | type == "string") and (.id | length > 0))' \
    >/dev/null 2>&1 <<<"$1"
}

janus_extract_model_ids() {
  janus_catalog_validate_json "$1" || return $?
  jq -r '.data[].id' <<<"$1"
}

janus_catalog_contains() {
  local json="$1" id="$2"
  janus_catalog_validate_json "$json" || return $?
  jq -e --arg id "$id" 'any(.data[]; .id == $id)' >/dev/null 2>&1 <<<"$json"
}

janus_fetch_catalog() {
  local base="$1" key="$2"
  command -v curl >/dev/null 2>&1 || {
    printf 'Janus Launcher requires curl.\n' >&2
    return 127
  }
  curl -fsS --max-time 8 \
    -A 'janus-launcher/1.0' \
    -H "Authorization: Bearer $key" \
    -H 'Accept: application/json' \
    "$(janus_api_root "$base")/models"
}

janus_validate_service() {
  local base="$1" key="$2" body ids rc
  command -v curl >/dev/null 2>&1 || {
    printf 'Janus Launcher requires curl.\n' >&2
    return 127
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'Janus Launcher requires jq.\n' >&2
    return 127
  }

  curl -fsS -o /dev/null --max-time 3 \
    -A 'janus-launcher/1.0' \
    "$(janus_api_root "$base")/health" || return 1

  body="$(janus_fetch_catalog "$base" "$key")" || {
    rc=$?
    [[ $rc -eq 127 ]] && return 127
    return 2
  }
  janus_catalog_validate_json "$body" || {
    rc=$?
    [[ $rc -eq 127 ]] && return 127
    return 3
  }
  ids="$(janus_extract_model_ids "$body")" || {
    rc=$?
    [[ $rc -eq 127 ]] && return 127
    return 3
  }
  [[ -n "$ids" ]] || return 4
  printf '%s\n' "$body"
}

janus_check_health() {
  janus_validate_service "$@" >/dev/null
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    127) return 127 ;;
    *) return 2 ;;
  esac
}
