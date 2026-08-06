#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${JANUS_LAUNCHER_INSTALL_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${JANUS_LAUNCHER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/janus-launcher}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/janus-launcher"
ROUTER_CONFIG="$CONFIG_DIR/router.conf"
LIB_DIR="$DATA_DIR/lib"

fail() {
  printf 'Janus Launcher installer: %s\n' "$1" >&2
  exit 1
}

if ! mkdir -p -- "$INSTALL_DIR"; then
  fail "cannot create installation directory: $INSTALL_DIR"
fi
[[ -d "$INSTALL_DIR" && -w "$INSTALL_DIR" ]] || fail "cannot write installation directory: $INSTALL_DIR"
if ! mkdir -p -- "$CONFIG_DIR" || ! chmod 700 "$CONFIG_DIR"; then
  fail "cannot create or secure configuration directory: $CONFIG_DIR"
fi
if ! mkdir -p -- "$LIB_DIR"; then
  fail "cannot create shared library directory: $LIB_DIR"
fi

for command in janus-launcher claude-janus codex-janus janus-control; do
  install -m 0755 "$ROOT_DIR/bin/$command" "$INSTALL_DIR/$command" ||
    fail "cannot install command: $INSTALL_DIR/$command"
done
for library in janus_api.sh janus_config.sh janus_runtime.sh janus_ui.sh; do
  install -m 0644 "$ROOT_DIR/lib/$library" "$LIB_DIR/$library" ||
    fail "cannot install library: $LIB_DIR/$library"
done

if [[ ! -e "$ROUTER_CONFIG" ]]; then
  install -m 0600 "$ROOT_DIR/config.example" "$ROUTER_CONFIG" ||
    fail "cannot create router configuration: $ROUTER_CONFIG"
  created_config=1
elif [[ ! -f "$ROUTER_CONFIG" ]]; then
  fail "router configuration is not a regular file: $ROUTER_CONFIG"
else
  # Validate existing configuration with the same strict parser used at runtime.
  # shellcheck source=lib/janus_api.sh
  source "$ROOT_DIR/lib/janus_api.sh"
  # shellcheck source=lib/janus_config.sh
  source "$ROOT_DIR/lib/janus_config.sh"
  janus_config_load_router "$ROUTER_CONFIG" ||
    fail "invalid router configuration; fix the existing file: $ROUTER_CONFIG"
  chmod 600 "$ROUTER_CONFIG" || fail "cannot secure router configuration: $ROUTER_CONFIG"
  created_config=0
fi

for command in janus-launcher claude-janus codex-janus janus-control; do
  printf 'Installed %s → %s\n' "$command" "$INSTALL_DIR/$command"
done
printf 'Installed shared libraries → %s\n' "$LIB_DIR"
if [[ $created_config -eq 1 ]]; then
  printf 'Created configuration → %s\n' "$ROUTER_CONFIG"
  printf 'Edit that file and replace the example URL and API key before launching.\n'
else
  printf 'Preserved existing configuration → %s\n' "$ROUTER_CONFIG"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) printf 'PATH reminder: add %s to PATH to run the installed commands.\n' "$INSTALL_DIR" ;;
esac
