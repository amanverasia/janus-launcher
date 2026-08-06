#!/usr/bin/env bash
# Managed Codex desktop-app integration for Janus Launcher.

if [[ -n "${JANUS_CODEX_APP_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
JANUS_CODEX_APP_SH_LOADED=1

JANUS_CODEX_APP_ROOT_START='# BEGIN janus-launcher-codex-app-managed'
JANUS_CODEX_APP_ROOT_END='# END janus-launcher-codex-app-managed'
JANUS_CODEX_APP_PROVIDER_START='# BEGIN janus-launcher-codex-provider-managed'
JANUS_CODEX_APP_PROVIDER_END='# END janus-launcher-codex-provider-managed'

janus_codex_app_init_paths() {
  janus_config_init_paths
  JANUS_CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
  JANUS_CODEX_APP_CONFIG="$JANUS_CODEX_HOME_DIR/config.toml"
  JANUS_CODEX_APP_CATALOG="$JANUS_CONFIG_DIR/codex-app-models.json"
  JANUS_CODEX_APP_STATE="$JANUS_CONFIG_DIR/codex-app-state.json"
  JANUS_CODEX_APP_ORIGINAL="$JANUS_CONFIG_DIR/codex-app-config.original"
  JANUS_CODEX_APP_MANAGED="$JANUS_CONFIG_DIR/codex-app-config.managed"
  JANUS_CODEX_APP_LOCK="$JANUS_CONFIG_DIR/.codex-app.lock"
}

janus_codex_app_validate_paths() {
  if [[ -L "$JANUS_CONFIG_DIR" || (-e "$JANUS_CONFIG_DIR" && ! -d "$JANUS_CONFIG_DIR") ]]; then
    printf 'janus-control: Janus configuration directory is not a safe directory.\n' >&2
    return 2
  fi
  if [[ -L "$JANUS_CODEX_HOME_DIR" || (-e "$JANUS_CODEX_HOME_DIR" && ! -d "$JANUS_CODEX_HOME_DIR") ]]; then
    printf 'janus-control: CODEX_HOME is not a safe directory.\n' >&2
    return 2
  fi
  if [[ -L "$JANUS_CODEX_APP_CONFIG" || (-e "$JANUS_CODEX_APP_CONFIG" && ! -f "$JANUS_CODEX_APP_CONFIG") ]]; then
    printf 'janus-control: Codex config.toml is not a regular, non-symlink file.\n' >&2
    return 2
  fi
}

janus_codex_app_lock_acquire() {
  mkdir -p -- "$JANUS_CONFIG_DIR" && chmod 700 "$JANUS_CONFIG_DIR" || return
  if ! mkdir "$JANUS_CODEX_APP_LOCK" 2>/dev/null; then
    printf 'janus-control: another Codex app configuration operation is in progress.\n' >&2
    return 2
  fi
  chmod 700 "$JANUS_CODEX_APP_LOCK"
}

janus_codex_app_lock_release() {
  rmdir "$JANUS_CODEX_APP_LOCK" 2>/dev/null || true
}

janus_codex_app_binary() {
  local candidate
  if [[ -n "${JANUS_LAUNCHER_CODEX_APP_BIN:-}" ]]; then
    candidate="$JANUS_LAUNCHER_CODEX_APP_BIN"
    if [[ "$candidate" != /* || -L "$candidate" || ! -f "$candidate" || ! -x "$candidate" ]]; then
      printf 'janus-control: JANUS_LAUNCHER_CODEX_APP_BIN must be an absolute executable regular file.\n' >&2
      return 2
    fi
    printf '%s\n' "$candidate"
    return 0
  fi
  # The desktop app must consume a catalog shaped for its bundled Codex build.
  if [[ -x /Applications/ChatGPT.app/Contents/Resources/codex ]]; then
    printf '%s\n' /Applications/ChatGPT.app/Contents/Resources/codex
  else
    candidate="$(janus_resolve_client_executable codex "${BASH_SOURCE[0]}" || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
    else
      return 127
    fi
  fi
}

janus_codex_app_require_chatgpt_login() {
  local binary="$1" output status
  if output="$("$binary" login status 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [[ $status -eq 0 && "$output" == 'Logged in using ChatGPT'* ]]; then
    return 0
  fi
  if [[ $status -eq 1 && "$output" == *'Not logged in'* ]]; then
    printf 'janus-control: Codex is signed out; sign in to ChatGPT before enabling Janus app models.\n' >&2
  else
    printf 'janus-control: cannot confirm a supported ChatGPT login; refusing to modify Codex app configuration.\n' >&2
  fi
  return 2
}

janus_codex_app_managed_layout() {
  local file="$1" expected="$2"
  awk -v rs="$JANUS_CODEX_APP_ROOT_START" -v re="$JANUS_CODEX_APP_ROOT_END" \
    -v ps="$JANUS_CODEX_APP_PROVIDER_START" -v pe="$JANUS_CODEX_APP_PROVIDER_END" \
    -v expected="$expected" '
    $0 == rs { if (root || provider) exit 2; root=1; rsc++ }
    $0 == re { if (!root || provider) exit 2; root=0; rec++ }
    $0 == ps { if (root || provider) exit 2; provider=1; psc++ }
    $0 == pe { if (root || !provider) exit 2; provider=0; pec++ }
    END {
      if (root || provider) exit 2
      if (expected == "present" && !(rsc == 1 && rec == 1 && psc == 1 && pec == 1)) exit 1
      if (expected == "absent" && (rsc || rec || psc || pec)) exit 1
    }
  ' "$file"
}

janus_codex_app_user_provider_exists() {
  awk '
    {
      line=$0
      gsub(/[[:space:]]/, "", line)
      if (line == "[model_providers.janus]" || line == "[model_providers.\"janus\"]" ||
        line == "[model_providers.\047janus\047]" ||
        line ~ /^model_providers=/ || line ~ /^\"model_providers\"=/ || line ~ /^\047model_providers\047=/) found=1
    }
    END { exit !found }
  ' "$1"
}

janus_codex_app_remove_file() {
  local file="$1"
  if [[ -e "$file" ]]; then
    rm -f -- "$file"
  else
    return 0
  fi
}

janus_codex_app_root_line() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v key="$key" '
    /^[[:space:]]*\[/ { exit }
    {
      line=$0
      gsub(/[[:space:]]/, "", line)
      if (line ~ ("^" key "=") || line ~ ("^\\\"" key "\\\"=") ||
        line ~ ("^\\047" key "\\047=")) { print; found=1; exit }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

janus_codex_app_strip_managed() {
  awk -v rs="$JANUS_CODEX_APP_ROOT_START" -v re="$JANUS_CODEX_APP_ROOT_END" \
    -v ps="$JANUS_CODEX_APP_PROVIDER_START" -v pe="$JANUS_CODEX_APP_PROVIDER_END" '
    $0 == rs || $0 == ps { skip=1; next }
    $0 == re || $0 == pe { skip=0; next }
    !skip { print }
  ' "$1"
}

janus_codex_app_rewrite_root() {
  local input="$1" output="$2" mode="$3" model_line="$4" provider_line="$5" catalog_line="$6"
  awk -v mode="$mode" -v rs="$JANUS_CODEX_APP_ROOT_START" -v re="$JANUS_CODEX_APP_ROOT_END" \
    -v model_line="$model_line" -v provider_line="$provider_line" -v catalog_line="$catalog_line" '
    function insert_values() {
      if (inserted) return
      if (mode == "enable") {
        print rs
        print model_line
        print provider_line
        print catalog_line
        print re
      } else {
        if (model_line != "") print model_line
        if (provider_line != "") print provider_line
        if (catalog_line != "") print catalog_line
      }
      inserted=1
    }
    BEGIN { root=1 }
    root && /^[[:space:]]*\[/ { insert_values(); root=0 }
    root && /^[[:space:]]*(model|model_provider|model_catalog_json)[[:space:]]*=/ { next }
    { print }
    END { if (root) insert_values() }
  ' "$input" > "$output"
}

janus_codex_app_write_state() {
  local model_line="$1" provider_line="$2" catalog_line="$3" config_existed="$4" temporary
  mkdir -p -- "$JANUS_CONFIG_DIR" && chmod 700 "$JANUS_CONFIG_DIR"
  temporary="$(mktemp "$JANUS_CONFIG_DIR/.codex-app-state.XXXXXX")" || return
  if ! jq -n --arg model "$model_line" --arg provider "$provider_line" --arg catalog "$catalog_line" \
    --argjson config_existed "$config_existed" \
    '{version:1,config_existed:$config_existed,previous:{model:$model,model_provider:$provider,model_catalog_json:$catalog}}' > "$temporary" ||
    ! chmod 600 "$temporary" || ! mv -f "$temporary" "$JANUS_CODEX_APP_STATE"; then
    janus_codex_app_remove_file "$temporary"
    return 1
  fi
}

janus_codex_app_save_snapshot() {
  local source="$1" destination="$2" temporary
  mkdir -p -- "$JANUS_CONFIG_DIR" && chmod 700 "$JANUS_CONFIG_DIR"
  temporary="$(mktemp "$JANUS_CONFIG_DIR/.codex-app-snapshot.XXXXXX")" || return
  if ! cp "$source" "$temporary" || ! chmod 600 "$temporary" ||
    ! mv -f "$temporary" "$destination"; then
    janus_codex_app_remove_file "$temporary"
    return 1
  fi
}

janus_codex_app_build_catalog() {
  local binary="$1" janus_catalog="$2" probe_home native temporary
  probe_home="$(mktemp -d "${TMPDIR:-/tmp}/janus-codex-catalog.XXXXXX")" || return
  if ! native="$(CODEX_HOME="$probe_home" "$binary" debug models --bundled 2>/dev/null)"; then
    rm -rf -- "$probe_home"
    printf 'janus-control: cannot read the bundled Codex model catalog.\n' >&2
    return 1
  fi
  rm -rf -- "$probe_home"
  mkdir -p -- "$JANUS_CONFIG_DIR" && chmod 700 "$JANUS_CONFIG_DIR"
  temporary="$(mktemp "$JANUS_CONFIG_DIR/.codex-app-models.XXXXXX")" || return
  if ! jq -n --argjson native "$native" --argjson janus "$janus_catalog" '
    ($native.models | map(select(.visibility == "list")) | .[0] // $native.models[0]) as $template |
    {models: [
      $janus.data | to_entries[] |
      .key as $index | .value.id as $id |
      ($template | del(.base_instructions, .model_messages, .comp_hash)) + {
        slug: $id,
        display_name: $id,
        description: "Janus catalog model",
        priority: ($index + 1),
        visibility: "list",
        supported_in_api: true,
        default_reasoning_level: "medium",
        supported_reasoning_levels: [{effort:"medium", description:"Balanced reasoning"}],
        context_window: 32768,
        max_context_window: 32768,
        auto_compact_token_limit: 28000,
        effective_context_window_percent: 95,
        input_modalities: ["text"],
        supports_search_tool: false,
        supports_image_detail_original: false,
        supports_parallel_tool_calls: false,
        experimental_supported_tools: [],
        support_verbosity: false,
        default_verbosity: null,
        additional_speed_tiers: [],
        service_tiers: [],
        availability_nux: null,
        upgrade: null,
        multi_agent_version: "v1"
      }
    ]}' > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary" && mv -f "$temporary" "$JANUS_CODEX_APP_CATALOG"
}

janus_codex_app_preflight() {
  local binary="$1" candidate="$2" probe_home
  probe_home="$(mktemp -d "${TMPDIR:-/tmp}/janus-codex-preflight.XXXXXX")" || return
  if ! cp "$candidate" "$probe_home/config.toml" ||
    ! CODEX_HOME="$probe_home" "$binary" debug models >/dev/null 2>&1; then
    rm -rf -- "$probe_home"
    printf 'janus-control: generated Codex configuration failed bundled-client validation.\n' >&2
    return 1
  fi
  rm -rf -- "$probe_home"
}

janus_codex_app_enable_locked() {
  local model="$1" control_bin="$2" binary current cleaned rewritten final state_was_present=0
  local config_existed=false
  local previous_model='' previous_provider='' previous_catalog='' quoted_model quoted_catalog quoted_url quoted_control
  janus_codex_app_init_paths
  binary="$(janus_codex_app_binary)" || {
    printf 'janus-control: Codex binary not found.\n' >&2
    return 127
  }
  janus_codex_app_require_chatgpt_login "$binary" || return
  janus_catalog_contains "$JANUS_CATALOG_JSON" "$model" || {
    printf 'janus-control: model is not in the Janus catalog: %s\n' "$model" >&2
    return 2
  }
  mkdir -p -- "$JANUS_CODEX_HOME_DIR" && chmod 700 "$JANUS_CODEX_HOME_DIR"
  current="$(mktemp "$JANUS_CODEX_HOME_DIR/.janus-current.XXXXXX")" || return
  if [[ -f "$JANUS_CODEX_APP_CONFIG" ]]; then
    config_existed=true
    cp "$JANUS_CODEX_APP_CONFIG" "$current"
  else
    : > "$current"
  fi
  if [[ -f "$JANUS_CODEX_APP_STATE" ]]; then
    state_was_present=1
    if ! janus_codex_app_managed_layout "$current" present; then
      janus_codex_app_remove_file "$current"
      printf 'janus-control: managed Codex configuration is missing or damaged; refusing to overwrite it.\n' >&2
      return 2
    fi
    if ! previous_model="$(jq -er 'select(.version == 1 and (.previous.model | type == "string") and (.previous.model_provider | type == "string") and (.previous.model_catalog_json | type == "string")) | .previous.model' "$JANUS_CODEX_APP_STATE")" ||
      ! previous_provider="$(jq -er '.previous.model_provider' "$JANUS_CODEX_APP_STATE")" ||
      ! previous_catalog="$(jq -er '.previous.model_catalog_json' "$JANUS_CODEX_APP_STATE")"; then
      janus_codex_app_remove_file "$current"
      printf 'janus-control: managed Codex integration state is invalid; refusing to overwrite configuration.\n' >&2
      return 2
    fi
  else
    if ! janus_codex_app_managed_layout "$current" absent; then
      janus_codex_app_remove_file "$current"
      printf 'janus-control: found unmanaged Janus Launcher markers in Codex configuration.\n' >&2
      return 2
    fi
    if janus_codex_app_user_provider_exists "$current"; then
      janus_codex_app_remove_file "$current"
      printf 'janus-control: refusing to replace user-owned model_providers.janus.\n' >&2
      return 2
    fi
    previous_model="$(janus_codex_app_root_line "$current" model || true)"
    previous_provider="$(janus_codex_app_root_line "$current" model_provider || true)"
    previous_catalog="$(janus_codex_app_root_line "$current" model_catalog_json || true)"
    if [[ -n "$previous_catalog" ]]; then
      janus_codex_app_remove_file "$current"
      printf 'janus-control: refusing to replace user-owned model_catalog_json.\n' >&2
      return 2
    fi
  fi
  if ! janus_codex_app_build_catalog "$binary" "$JANUS_CATALOG_JSON"; then
    janus_codex_app_remove_file "$current"
    return 1
  fi
  quoted_model="$(jq -Rn --arg value "$model" '$value')"
  quoted_catalog="$(jq -Rn --arg value "$JANUS_CODEX_APP_CATALOG" '$value')"
  quoted_url="$(jq -Rn --arg value "$(janus_api_root "$JANUS_BASE_URL")" '$value')"
  quoted_control="$(jq -Rn --arg value "$control_bin" '$value')"
  cleaned="$(mktemp "$JANUS_CODEX_HOME_DIR/.janus-clean.XXXXXX")" || return
  rewritten="$(mktemp "$JANUS_CODEX_HOME_DIR/.janus-root.XXXXXX")" || {
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"; return 1;
  }
  final="$(mktemp "$JANUS_CODEX_HOME_DIR/.janus-final.XXXXXX")" || {
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned";
    janus_codex_app_remove_file "$rewritten"; return 1;
  }
  if ! janus_codex_app_strip_managed "$current" > "$cleaned" ||
    ! janus_codex_app_rewrite_root "$cleaned" "$rewritten" enable \
    "model = $quoted_model" 'model_provider = "janus"' "model_catalog_json = $quoted_catalog"
  then
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"
    janus_codex_app_remove_file "$rewritten"; janus_codex_app_remove_file "$final"
    return 1
  fi
  cp "$rewritten" "$final"
  if ! printf '\n%s\n[model_providers.janus]\nname = "Janus"\nbase_url = %s\nwire_api = "responses"\n\n[model_providers.janus.auth]\ncommand = %s\nargs = ["codex-token", %s]\n%s\n' \
    "$JANUS_CODEX_APP_PROVIDER_START" "$quoted_url" "$quoted_control" "$quoted_url" "$JANUS_CODEX_APP_PROVIDER_END" >> "$final" ||
    ! chmod 600 "$final"; then
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"
    janus_codex_app_remove_file "$rewritten"; janus_codex_app_remove_file "$final"
    return 1
  fi
  if ! janus_codex_app_preflight "$binary" "$final"; then
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"
    janus_codex_app_remove_file "$rewritten"; janus_codex_app_remove_file "$final"
    return 1
  fi
  if ((state_was_present == 0)); then
    if ! janus_codex_app_save_snapshot "$current" "$JANUS_CODEX_APP_ORIGINAL"; then
      janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"
      janus_codex_app_remove_file "$rewritten"; janus_codex_app_remove_file "$final"
      janus_codex_app_remove_file "$JANUS_CODEX_APP_ORIGINAL"
      return 1
    fi
  fi
  if ! mv -f "$final" "$JANUS_CODEX_APP_CONFIG" || ! chmod 600 "$JANUS_CODEX_APP_CONFIG" ||
    ! janus_codex_app_save_snapshot "$JANUS_CODEX_APP_CONFIG" "$JANUS_CODEX_APP_MANAGED"; then
    if [[ "$config_existed" == true || $state_was_present -eq 1 ]]; then
      cp "$current" "$JANUS_CODEX_APP_CONFIG" && chmod 600 "$JANUS_CODEX_APP_CONFIG" || true
    else
      janus_codex_app_remove_file "$JANUS_CODEX_APP_CONFIG"
    fi
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"
    janus_codex_app_remove_file "$rewritten"; janus_codex_app_remove_file "$final"
    return 1
  fi
  if ((state_was_present == 0)) &&
    ! janus_codex_app_write_state "$previous_model" "$previous_provider" "$previous_catalog" "$config_existed"; then
    if [[ "$config_existed" == true ]]; then
      cp "$JANUS_CODEX_APP_ORIGINAL" "$JANUS_CODEX_APP_CONFIG" && chmod 600 "$JANUS_CODEX_APP_CONFIG" || true
    else
      janus_codex_app_remove_file "$JANUS_CODEX_APP_CONFIG"
    fi
    janus_codex_app_remove_file "$JANUS_CODEX_APP_ORIGINAL"
    janus_codex_app_remove_file "$JANUS_CODEX_APP_MANAGED"
    janus_codex_app_remove_file "$current"; janus_codex_app_remove_file "$cleaned"
    janus_codex_app_remove_file "$rewritten"
    return 1
  fi
  janus_codex_app_remove_file "$current"
  janus_codex_app_remove_file "$cleaned"
  janus_codex_app_remove_file "$rewritten"
  printf 'Codex app Janus-only mode enabled for %s (%s Janus models).\n' \
    "$model" "$(jq -r '.models | length' "$JANUS_CODEX_APP_CATALOG")"
  printf 'Fully quit and reopen the Codex app; its model picker is now scoped to Janus models.\n'
}

janus_codex_app_enable() {
  local status
  janus_codex_app_init_paths
  janus_codex_app_validate_paths || return
  janus_codex_app_lock_acquire || return
  if janus_codex_app_enable_locked "$@"; then status=0; else status=$?; fi
  janus_codex_app_lock_release
  return "$status"
}

janus_codex_app_disable_locked() {
  local restored config_existed
  janus_codex_app_init_paths
  if [[ ! -f "$JANUS_CODEX_APP_STATE" ]]; then
    printf 'Codex app integration is not enabled.\n'
    return 0
  fi
  if [[ ! -f "$JANUS_CODEX_APP_CONFIG" ]]; then
    printf 'janus-control: managed state exists but Codex config.toml is missing; refusing to discard recovery state.\n' >&2
    return 2
  fi
  if ! janus_codex_app_managed_layout "$JANUS_CODEX_APP_CONFIG" present; then
    printf 'janus-control: managed Codex configuration is missing or damaged; refusing to rewrite it.\n' >&2
    return 2
  fi
  config_existed="$(jq -er 'select(.version == 1 and (.config_existed | type == "boolean")) | .config_existed' "$JANUS_CODEX_APP_STATE")" || {
    printf 'janus-control: managed Codex integration state is invalid; refusing to rewrite configuration.\n' >&2
    return 2
  }
  if [[ ! -f "$JANUS_CODEX_APP_ORIGINAL" || ! -f "$JANUS_CODEX_APP_MANAGED" ]]; then
    printf 'janus-control: managed Codex recovery snapshots are missing; refusing to rewrite configuration.\n' >&2
    return 2
  fi
  if ! cmp -s "$JANUS_CODEX_APP_CONFIG" "$JANUS_CODEX_APP_MANAGED"; then
    printf 'janus-control: Codex config.toml changed after enable; refusing to overwrite user edits.\n' >&2
    return 2
  fi
  restored="$(mktemp "$JANUS_CODEX_HOME_DIR/.janus-restored.XXXXXX")" || return
  if [[ "$config_existed" == true ]]; then
    cp "$JANUS_CODEX_APP_ORIGINAL" "$restored"
    chmod 600 "$restored" && mv -f "$restored" "$JANUS_CODEX_APP_CONFIG"
  else
    janus_codex_app_remove_file "$restored"
    janus_codex_app_remove_file "$JANUS_CODEX_APP_CONFIG"
  fi
  janus_codex_app_remove_file "$JANUS_CODEX_APP_STATE"
  janus_codex_app_remove_file "$JANUS_CODEX_APP_CATALOG"
  janus_codex_app_remove_file "$JANUS_CODEX_APP_ORIGINAL"
  janus_codex_app_remove_file "$JANUS_CODEX_APP_MANAGED"
  printf 'Codex app integration disabled; previous model/provider settings restored.\n'
}

janus_codex_app_disable() {
  local status
  janus_codex_app_init_paths
  janus_codex_app_validate_paths || return
  janus_codex_app_lock_acquire || return
  if janus_codex_app_disable_locked "$@"; then status=0; else status=$?; fi
  janus_codex_app_lock_release
  return "$status"
}

janus_codex_app_status() {
  janus_codex_app_init_paths
  janus_codex_app_validate_paths || return
  if [[ -f "$JANUS_CODEX_APP_STATE" ]]; then
    if [[ ! -f "$JANUS_CODEX_APP_CONFIG" || ! -f "$JANUS_CODEX_APP_MANAGED" ]] ||
      ! janus_codex_app_managed_layout "$JANUS_CODEX_APP_CONFIG" present ||
      ! cmp -s "$JANUS_CODEX_APP_CONFIG" "$JANUS_CODEX_APP_MANAGED"; then
      printf 'Codex app integration: damaged (managed files changed or missing)\n'
      return 2
    fi
    printf 'Codex app integration: enabled\n'
    janus_codex_app_root_line "$JANUS_CODEX_APP_CONFIG" model || true
    [[ -f "$JANUS_CODEX_APP_CATALOG" ]] && printf 'Catalog models: %s\n' "$(jq -r '.models | length' "$JANUS_CODEX_APP_CATALOG")"
  else
    printf 'Codex app integration: disabled\n'
  fi
}
