#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/tests/test_janus_api.sh"
"$ROOT/tests/test_janus_config.sh"
"$ROOT/tests/test_janus_runtime.sh"
"$ROOT/tests/test_janus_ui.sh"
"$ROOT/tests/test_claude_launcher.sh"
"$ROOT/tests/test_codex_launcher.sh"
"$ROOT/tests/arrow_keys.py"
python3 "$ROOT/tests/subagent_mapping.py"
