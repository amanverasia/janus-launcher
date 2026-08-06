# Janus Launcher

**Claude Code and Codex launchers for [Janus](https://github.com/amanverasia/Janus)**, the multi-provider AI gateway.

Janus Launcher keeps one private Janus connection and delegates to focused client launchers. Claude Code uses four independent role mappings through Janus's Anthropic-compatible Messages API. Codex uses one model through Janus's OpenAI Responses API. Installation and normal CLI launches do not modify shell profiles or the user's normal Codex configuration; persistent Codex desktop-app integration is a separate, explicit, reversible opt-in.

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

Janus-compatible control-plane commands are also available. The `models`,
`status`, and `doctor` commands only call Janus's health and catalog endpoints;
they never modify Codex configuration or send inference requests. The explicit
`codex-app` commands described below manage persistent desktop-app integration.

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
codex-app-models.json
codex-app-state.json
codex-app-config.original
codex-app-config.managed
```

The optional `codex-app-*` artifacts are created by persistent Codex desktop-app
integration. The state file and private configuration snapshots support safe
restoration; the generated catalog may remain after the integration is
disabled.

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

The CLI launcher passes temporary `-c` provider overrides to Codex with a normalized `<Janus base>/v1`, `wire_api="responses"`, and the API key delivered through `JANUS_LAUNCHER_CODEX_API_KEY`. It does not edit `~/.codex/config.toml`, create a profile, or make a generation probe. Therefore the Janus deployment must implement `POST /v1/responses`.

Before contacting Janus, the launcher asks Codex to parse its existing
configuration with the read-only `features list` command. On macOS, if the
`codex` found on `PATH` is missing, outdated, or cannot parse the current
configuration, the launcher automatically uses the compatible Codex binary
bundled with the ChatGPT desktop app when available. Otherwise it prints an actionable
configuration error instead of failing after model selection.

On the first interactive CLI launch, choose a model from the Janus catalog. The
choice is saved in `codex.conf` and reused on later launches:

```bash
codex-janus
```

To reopen the searchable picker and replace the saved CLI choice, run:

```bash
codex-janus --select-model
```

If you already know the exact Janus catalog ID, select it for one invocation
without changing the saved choice:

```bash
codex-janus --model provider/model-id
```

Caller `-m MODEL`, `--model MODEL`, and `--model=MODEL` selections take
precedence for that invocation without rewriting saved state. A missing or stale
saved model opens the catalog picker only on an interactive terminal;
noninteractive use fails with corrective guidance.

Large catalogs open with a search prompt instead of printing every model. Type a
provider or model fragment to filter, type an exact catalog number, or press
Enter to browse 20 results at a time. Every interactive menu accepts a complete
number followed by Enter; arrow keys remain available for nearby choices.

The launchers reserve the temporary Janus provider keys they own but preserve unrelated Codex `-c` overrides and other client arguments.

### Persistent Codex desktop app: safe direct fallback

CLI launches use temporary provider overrides. Persistent desktop-app
integration is an explicit opt-in, and its behavior depends on who already owns
Codex's model catalog. Use an exact ID from `janus-control models`:

```bash
janus-control models
janus-control codex-app enable provider/model-id
```

Enable verifies that Codex reports a signed-in account state before changing
configuration. It refuses to proceed when Codex is signed out or its account
state cannot be determined.

The enable command inspects the existing Codex configuration before writing:

- If no existing model-catalog owner is present, it enables a direct,
  Janus-only fallback. It replaces the active model, provider, and catalog
  settings with the selected Janus model, the managed Janus provider, and the
  current Janus catalog. Native GPT entries are not shown in this mode.
- If supported Codex Router `0.4.0-beta.2` already owns the catalog, enable
  refuses without changing Codex or Router files. Router-shaped catalogs with
  an unknown version or layout also fail closed. Janus Launcher does not
  overwrite Router's managed `openai_base_url`, merged catalog, provider,
  service, or state.

Stock Codex Router `0.4.0-beta.2` has no safe user-provider extension that can
persist an arbitrary Janus endpoint while rebuilding both its merged picker and
its LiteLLM routes. Patching Router's managed source checkout would make normal
updates and rollbacks unsafe, so this release deliberately does not attempt that
bridge. When Router owns the catalog, continue to use `codex-janus` for Janus
CLI sessions; native-plus-Janus desktop merging requires supported Janus
provider integration in Codex Router itself.

The managed settings are written to
`${CODEX_HOME:-$HOME/.codex}/config.toml`; a normal desktop-app launch then uses
them. The enable command configures the app but does not launch it.

After a successful enable, re-enable with a different model, or disable, fully
quit and reopen the Codex desktop app. Closing only a window is not enough for
the app to reload its configuration. A refused enable makes no change and does
not require a restart.

Check whether the managed integration is active, or remove it, with:

```bash
janus-control codex-app status
janus-control codex-app disable
```

`status` is read-only. It reports Janus direct mode as enabled or disabled; for
a recognized Router-owned catalog it reports Codex Router as the external owner,
that the Janus bridge is unavailable, and that Janus made no changes. `disable`
restores only Janus-owned direct mode and does not disable or alter Codex Router.

In direct mode, the first enable records the previous active model, provider,
and catalog settings and saves private original and managed configuration
snapshots. Disable restores the pre-enable configuration. If `config.toml` is
missing, damaged, or was edited after enable, disable refuses to overwrite it or
discard its recovery state. Enable likewise refuses to replace an existing
user-owned `janus` provider or an existing catalog owner. These safeguards keep
the fallback reversible without silently destroying user configuration.

Janus Launcher does not patch a detected Codex Router installation, so Router's
own update, rollback, and restore commands remain authoritative. Do not remove
Janus Launcher's `codex-app-state.json` or configuration snapshots while direct
mode is active; use `janus-control codex-app disable` to restore the saved
configuration first.

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
- Claude receives the credential only in its child environment. Codex CLI reads it through the named temporary provider environment key; the managed desktop provider retrieves it through `janus-control` without storing it in `config.toml`.

## License

[MIT](LICENSE)
