#!/usr/bin/env bash
# Safe Codex Router ownership detection for the Codex desktop integration.
#
# Codex Router 0.4.0-beta.2 has no persistent user-provider extension point.
# Its alternate-registry environment variable is not inherited by installed
# services, while editing its checked-in registry dirties the managed checkout
# and blocks safe updates.  Until upstream supplies such an extension, Janus
# detects Router ownership and refuses mutation rather than taking over the
# shared model_catalog_json setting or patching third-party files.

if [[ -n "${JANUS_CODEX_ROUTER_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
JANUS_CODEX_ROUTER_SH_LOADED=1

JANUS_CODEX_ROUTER_SUPPORTED_VERSION='0.4.0-beta.2'

janus_codex_router_init_paths() {
  janus_codex_app_init_paths
  JANUS_CODEX_ROUTER_BRIDGE_STATE="$JANUS_CONFIG_DIR/codex-router-bridge-state.json"
}

janus_codex_router_catalog_value() {
  local line value
  line="$(janus_codex_app_root_line "$JANUS_CODEX_APP_CONFIG" model_catalog_json || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  jq -er 'select(type == "string" and length > 0)' <<<"$value" 2>/dev/null
}

# Return 0 only for a verified, supported Codex Router owner; 1 when the
# catalog is not Router-owned; and 2 for a Router-shaped but unknown/unsafe
# layout.  Callers must propagate 2 so an unknown owner is never overwritten.
janus_codex_router_discover() {
  local catalog manifest source manifest_version package_version
  janus_codex_router_init_paths
  [[ -f "$JANUS_CODEX_APP_CONFIG" ]] || return 1
  catalog="$(janus_codex_router_catalog_value)" || return 1
  [[ "$catalog" == /* && "$(basename -- "$catalog")" == merged-models.json ]] || return 1

  JANUS_CODEX_ROUTER_STATE_DIR="$(dirname -- "$catalog")"
  manifest="$JANUS_CODEX_ROUTER_STATE_DIR/install-manifest.json"
  if [[ ! -f "$manifest" || -L "$manifest" ]]; then
    printf 'janus-control: model_catalog_json resembles Codex Router, but its install manifest is missing or unsafe.\n' >&2
    return 2
  fi
  source="$(jq -er 'select(.version == 1 and .current.target == "codex") | .current.sourceRoot | select(type == "string" and startswith("/"))' "$manifest" 2>/dev/null)" || {
    printf 'janus-control: Codex Router install manifest has an unknown layout.\n' >&2
    return 2
  }
  manifest_version="$(jq -er '.current.packageVersion | select(type == "string")' "$manifest" 2>/dev/null)" || {
    printf 'janus-control: Codex Router install manifest has no supported package version.\n' >&2
    return 2
  }

  if [[ -n "${JANUS_LAUNCHER_CODEX_ROUTER_DIR:-}" ]]; then
    if [[ "$JANUS_LAUNCHER_CODEX_ROUTER_DIR" != /* || "$source" != "$JANUS_LAUNCHER_CODEX_ROUTER_DIR" ]]; then
      printf 'janus-control: Codex Router override is not absolute or does not match its install manifest.\n' >&2
      return 2
    fi
  fi

  JANUS_CODEX_ROUTER_ROOT="$source"
  if [[ -L "$source" || ! -d "$source" || ! -f "$source/package.json" || -L "$source/package.json" ||
        ! -f "$source/config/providers.json" || -L "$source/config/providers.json" ]]; then
    printf 'janus-control: Codex Router checkout has an unsupported or unsafe layout.\n' >&2
    return 2
  fi
  package_version="$(jq -er '.version | select(type == "string")' "$source/package.json" 2>/dev/null)" || return 2
  if [[ "$package_version" != "$JANUS_CODEX_ROUTER_SUPPORTED_VERSION" || "$manifest_version" != "$package_version" ]]; then
    printf 'janus-control: unsupported Codex Router version %s (recognized: %s).\n' "$package_version" "$JANUS_CODEX_ROUTER_SUPPORTED_VERSION" >&2
    return 2
  fi
  jq -e '.version == 1 and (.providers | type == "array") and (.models | type == "array")' \
    "$source/config/providers.json" >/dev/null 2>&1 || {
    printf 'janus-control: Codex Router provider registry has an unknown layout.\n' >&2
    return 2
  }
  [[ "$catalog" == "$JANUS_CODEX_ROUTER_STATE_DIR/merged-models.json" ]] || {
    printf 'janus-control: Codex Router catalog path has an unknown layout.\n' >&2
    return 2
  }
}

janus_codex_router_owns_catalog() {
  janus_codex_router_discover
}

janus_codex_router_refusal() {
  printf 'janus-control: Codex Router owns model_catalog_json.\n' >&2
  printf 'janus-control: Codex Router %s has no safe persistent user-provider extension; Janus will not patch its managed checkout, registry, credentials, user state, catalog, or service.\n' \
    "$JANUS_CODEX_ROUTER_SUPPORTED_VERSION" >&2
  printf 'janus-control: disable Codex Router before enabling Janus-only mode, or use a Router release with a first-class external provider extension.\n' >&2
  return 2
}

janus_codex_router_enable() {
  janus_codex_router_discover || return
  janus_codex_router_refusal
}

janus_codex_router_disable() {
  janus_codex_router_init_paths
  if [[ -e "$JANUS_CODEX_ROUTER_BRIDGE_STATE" ]]; then
    printf 'janus-control: obsolete Codex Router bridge state exists; refusing automatic cleanup because no safe bridge release was shipped.\n' >&2
    return 2
  fi
  printf 'Codex app integration is owned by Codex Router; Janus has nothing to disable.\n'
}

janus_codex_router_status() {
  janus_codex_router_discover || return
  printf 'Codex app integration: externally managed (Codex Router %s)\n' "$JANUS_CODEX_ROUTER_SUPPORTED_VERSION"
  printf 'Janus bridge: unavailable (Router lacks a safe persistent user-provider extension)\n'
  printf 'Janus changes: none\n'
}
