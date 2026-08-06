# Janus Launcher

**Claude Code and Codex launchers for [Janus](https://github.com/amanverasia/Janus)**, the multi-provider AI gateway.

Janus Launcher keeps one private Janus connection and delegates to focused client launchers. Claude Code uses four independent role mappings through Janus's Anthropic-compatible Messages API. Codex uses one model through Janus's OpenAI Responses API. The launchers do not modify shell profiles or the user's normal Codex configuration.

## Requirements

- Bash 4+
- `curl`
- `jq`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as `claude` when launching Claude
- [Codex CLI](https://github.com/openai/codex) as `codex` when launching Codex
- A Janus router exposing authenticated `GET /v1/models`, `GET /v1/health`, `POST /v1/messages` for Claude, and `POST /v1/responses` for Codex

Installation itself does not require either client executable. Python 3 is needed only for the repository's pseudo-terminal tests.

## Install

```bash
git clone https://github.com/amanverasia/janus-launcher.git
cd janus-launcher
./install.sh
```

The installer creates these commands in `${JANUS_LAUNCHER_INSTALL_DIR:-$HOME/.local/bin}`:

```text
janus-launcher
claude-janus
codex-janus
janus-control
```

Shared libraries are installed under `${XDG_DATA_HOME:-$HOME/.local/share}/janus-launcher/lib`. Ensure the command directory is on `PATH`.

## Usage

Use the dispatcher explicitly:

```bash
janus-launcher claude
janus-launcher codex
```

Or invoke a dedicated launcher:

```bash
claude-janus
codex-janus
```

Running `janus-launcher` without arguments opens an interactive client picker. In a noninteractive terminal it prints usage and fails instead of prompting. Arguments after the selected client pass through as an unchanged argument vector:

```bash
janus-launcher claude -p "Explain this repository"
janus-launcher codex exec "Review these changes"
```

Janus-compatible control-plane commands are also available. They carry over the
safe operational workflow of Codex Router while keeping all provider routing in
Janus: they only call Janus's health and catalog endpoints, never modify Codex
configuration or send inference requests.

```bash
janus-launcher models       # exact model IDs from Janus
janus-launcher status       # endpoint health and catalog size
janus-launcher doctor       # dependencies, configuration, and connectivity

# The control command may also be invoked directly.
janus-control doctor
```

`doctor` does not prompt or write configuration. It reports a missing or
placeholder router configuration with the exact corrective path, and it never
prints the API key.

Top-level client information commands (`-h`, `--help`, `-V`, `--version`, and `help`) bypass Janus setup and model selection. Other arguments retain the launcher's normal validation and routing behavior.

## Configuration and precedence

The default private configuration root is `${XDG_CONFIG_HOME:-$HOME/.config}/janus-launcher`, or `JANUS_LAUNCHER_CONFIG_DIR` when set:

```text
router.conf
claude-mappings.conf
codex.conf
```

`router.conf` stores the shared connection:

```ini
JANUS_BASE_URL=https://your-janus-router.example
JANUS_API_KEY=replace-with-your-key
```

`JANUS_LAUNCHER_BASE_URL` and `JANUS_LAUNCHER_API_KEY` override the corresponding file values for one invocation. `JANUS_LAUNCHER_CONFIG_DIR` overrides the entire configuration root. For noninteractive first-run setup, set both `JANUS_LAUNCHER_SETUP_BASE_URL` and `JANUS_LAUNCHER_SETUP_API_KEY`. The installer also accepts `JANUS_LAUNCHER_INSTALL_DIR`; standard `XDG_CONFIG_HOME` and `XDG_DATA_HOME` control their respective default roots.

This release is a clean break from `claude-janus`: it does not read or migrate `~/.config/claude-janus` and does not honor legacy `CLAUDE_JANUS_*`, `JANUS_BASE_URL`, or `JANUS_API_KEY` launcher overrides. Reconfigure Janus in the new `router.conf`; keep or remove the old directory separately.

The configuration directory is mode `700`, and `router.conf` and model state are mode `600`. Re-running the installer validates and preserves a valid existing `router.conf`; malformed configuration is rejected rather than overwritten.

## Claude Code

`claude-mappings.conf` stores independent routes for:

```ini
OPUS_MODEL=provider/model-id
SONNET_MODEL=provider/model-id
HAIKU_MODEL=provider/model-id
SUBAGENT_MODEL=provider/model-id
DEFAULT_TIER=sonnet
```

Claude starts with the saved tier and keeps Claude Code's `opus`, `sonnet`, and `haiku` interface while routing each tier to its mapped Janus model. Subagents use their independent mapping. Set `JANUS_LAUNCHER_CLAUDE_TIER=opus|sonnet|haiku` for a scriptable launch. If required mappings are unavailable in a noninteractive invocation, the launcher fails with corrective guidance instead of opening a menu.

## Codex

`codex.conf` stores exactly one route:

```ini
MODEL=provider/model-id
```

The launcher passes temporary `-c` provider overrides to Codex with a normalized `<Janus base>/v1`, `wire_api="responses"`, and the API key delivered through `JANUS_LAUNCHER_CODEX_API_KEY`. It does not edit `~/.codex/config.toml`, create a profile, or make a generation probe. Therefore the Janus deployment must implement `POST /v1/responses`.

Before contacting Janus, the launcher asks Codex to parse its existing
configuration with the read-only `features list` command. On macOS, if the
`codex` found on `PATH` is outdated or cannot parse the current configuration,
the launcher automatically uses the compatible Codex binary bundled with the
ChatGPT desktop app when available. Otherwise it prints an actionable
configuration error instead of failing after model selection.

Caller `-m MODEL`, `--model MODEL`, and `--model=MODEL` selections take precedence for that invocation without rewriting saved state. A missing or stale model opens the catalog picker only on an interactive terminal; noninteractive use fails with corrective guidance.

Large catalogs open with a search prompt instead of printing every model. Type a
provider or model fragment to filter, type an exact catalog number, or press
Enter to browse 20 results at a time. Every interactive menu accepts a complete
number followed by Enter; arrow keys remain available for nearby choices.

The launchers reserve the temporary Janus provider keys they own but preserve unrelated Codex `-c` overrides and other client arguments.

## Automation and troubleshooting

Inspect launch construction without executing a client:

```bash
JANUS_LAUNCHER_DRY_RUN=1 JANUS_LAUNCHER_CLAUDE_TIER=sonnet claude-janus
JANUS_LAUNCHER_DRY_RUN=1 codex-janus -m provider/model-id
```

Dry-run output redacts the API key. If a dedicated client executable is absent, its launcher exits `127`. Janus validation requires `curl` and `jq`; diagnostics identify missing dependencies or invalid configuration without printing secrets. Client endpoint errors, including a Janus deployment without Responses API support, pass through from the client unchanged.

## Updating

```bash
cd janus-launcher
git pull https://github.com/amanverasia/janus-launcher.git
./install.sh
```

Valid new-format router configuration and model state are preserved.

## Security

- Never commit a real API key.
- Keep the configuration directory private and `router.conf` at mode `600`.
- Prefer `JANUS_LAUNCHER_API_KEY` from a secret manager for ephemeral credentials.
- The key is never placed in client arguments, dry-run command output, or diagnostics.
- Claude receives the credential only in its child environment; Codex reads it through the named temporary provider environment key.

## License

[MIT](LICENSE)
