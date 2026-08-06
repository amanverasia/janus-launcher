# CLAUDE.md

This file provides guidance to coding agents working in this repository.

## Project

Janus Launcher is a standalone Bash 4+ tool that launches Claude Code and Codex through a Janus router. Keep the architecture client-focused: `janus-launcher` only dispatches, dedicated launchers own client contracts, and shared libraries own configuration, API, runtime, and terminal behavior. Do not rewrite the tool in another language or fold it into a Janus CLI without an explicit direction change.

The active identity and paths are `janus-launcher`. This is a clean break: never read, migrate, or honor active `claude-janus` configuration paths or `CLAUDE_JANUS_*` variables.

## Requirements

Runtime development assumes Bash 4+, `curl`, and `jq`. Actual launches additionally require `claude` or `codex` as appropriate. Python 3 standard-library pseudo-terminals run interactive tests. Tests use temporary fake clients and HTTP commands and must not contact a real Janus server.

## Commands

Run the complete suite exactly as CI does:

```bash
./tests/run.sh
```

Focused suites:

```bash
bash tests/test_janus_api.sh
bash tests/test_janus_config.sh
bash tests/test_janus_runtime.sh
bash tests/test_janus_ui.sh
bash tests/test_claude_launcher.sh
bash tests/test_codex_launcher.sh
bash tests/test_dispatcher.sh
bash tests/test_install.sh
python3 tests/arrow_keys.py
python3 tests/subagent_mapping.py
python3 tests/codex_model_selection.py
python3 tests/dispatcher_selection.py
```

Syntax and Python compilation checks:

```bash
bash -n bin/janus-launcher bin/claude-janus bin/codex-janus \
  lib/janus_api.sh lib/janus_config.sh lib/janus_runtime.sh lib/janus_ui.sh \
  install.sh tests/*.sh
python3 -m py_compile tests/*.py
git diff --check
```

Install locally with `./install.sh`. For dry launch construction use `JANUS_LAUNCHER_DRY_RUN=1`, plus `JANUS_LAUNCHER_CLAUDE_TIER=opus|sonnet|haiku` for Claude or a valid `-m MODEL` for Codex.

## File boundaries

- `bin/janus-launcher`: thin dispatcher only. Resolve sibling `claude-janus`/`codex-janus`/`janus-control` first, then `PATH`; preserve argv with arrays/direct `exec`. It may source only the UI library for the no-argument picker and must never load configuration/API logic or contact Janus.
- `bin/claude-janus`: Claude mappings, tier selection, Claude child environment, and `exec` contract.
- `bin/codex-janus`: one-model state, caller model parsing, owned provider overrides, TOML quoting, Codex child environment, and `exec` contract.
- `bin/janus-control`: read-only Janus model catalog, status, and doctor operations. It must never invoke a generation endpoint, change client configuration, or print credentials.
- `lib/janus_api.sh`: side-effect-free URL, catalog, health, and authenticated API functions.
- `lib/janus_config.sh`: new configuration paths, strict router parsing, precedence, secure atomic persistence, and first-run setup.
- `lib/janus_runtime.sh`: dependencies, executable resolution, top-level passthrough, and validated service orchestration.
- `lib/janus_ui.sh`: terminal initialization, navigation, rendering, traps, and restoration.
- `install.sh`: four executable and four library installation, explicit modes, new paths, strict preservation/validation of `router.conf`; it must not require either client executable.

## Process contracts

All real child commands use Bash arrays and end with `exec` so empty, spaced, quoted, and glob arguments, signals, stderr, and exit status are preserved.

Claude receives the normalized Janus base and credential through its child environment, blanks unrelated Anthropic API credentials, exports all four mappings, and invokes a Claude tier (`opus`, `sonnet`, or `haiku`) rather than a raw Janus model.

Codex receives temporary `-c` overrides selecting the Janus provider, normalized `<base>/v1`, `wire_api="responses"`, and `env_key="JANUS_LAUNCHER_CODEX_API_KEY"`. Never edit `~/.codex/config.toml`, create profiles, or probe `/v1/responses` with generation traffic. Preserve unrelated caller configuration overrides.

Top-level `-h`, `--help`, `-V`, `--version`, and `help` bypass Janus setup exactly; nested or prompt-contained text does not.

## Configuration and security

The default root is `${JANUS_LAUNCHER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/janus-launcher}` with `router.conf`, `claude-mappings.conf`, and `codex.conf`. Runtime connection overrides are exactly `JANUS_LAUNCHER_BASE_URL` and `JANUS_LAUNCHER_API_KEY`. Do not revive legacy environment precedence.

Treat API keys as secrets:

- never embed a key in command arguments, URLs, diagnostics, test failure output, or dry-run output;
- only read or securely persist it, put it in an authorization header, or assign it to the intended child environment;
- configuration directories should be mode `700`, state files mode `600`, and writes atomic where supported;
- tests may use obvious fake secrets but must explicitly verify redaction;
- review every `JANUS_API_KEY` occurrence before release.

Changes to parsing, terminal behavior, installation, or child process construction require focused regression tests first. Preserve historical design records unless they act as current instructions.
