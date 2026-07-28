# Janus Launcher Codex Support Design

**Date:** 2026-07-28
**Status:** Approved

## Objective

Rename the active product identity from Claude Janus to Janus Launcher and add first-class Codex CLI support without regressing the existing Claude Code workflow. One Janus connection and model catalog will serve both clients, while each client retains an invocation contract and persisted model state suited to that CLI.

## Scope

This change will:

- rename active product branding, paths, environment overrides, repository references, and documentation to Janus Launcher;
- update the Git `origin` URL to `https://github.com/amanverasia/janus-launcher.git`;
- install a central `janus-launcher` dispatcher alongside `claude-janus` and `codex-janus` commands;
- preserve Claude's four independent model mappings;
- add one persisted Codex model mapping;
- launch Codex through temporary custom-provider overrides without changing the user's normal Codex configuration;
- require the Janus deployment to implement the OpenAI Responses API at `/v1/responses`;
- reorganize common Janus, configuration, and terminal-selection behavior into shared modules; and
- update automated tests, installation, and active documentation.

The first Codex release will not manage reasoning effort, named Codex profiles, sandbox settings, or the user's `~/.codex/config.toml`. It will not bundle a Responses-to-Chat-Completions translation proxy. Historical design records will remain historical unless they currently function as active instructions.

## Product Identity and Commands

The product name becomes **Janus Launcher**. The rename is a deliberate clean break: the application will neither read nor migrate `~/.config/claude-janus`, and it will not honor legacy `CLAUDE_JANUS_*` variables.

Installation exposes three public commands:

- `janus-launcher` selects and delegates to a client;
- `claude-janus` launches Claude Code directly; and
- `codex-janus` launches Codex directly.

The central command supports these explicit forms:

```text
janus-launcher claude [arguments...]
janus-launcher codex [arguments...]
```

It removes the client token and delegates the remaining argument vector unchanged. With no client argument on an interactive terminal, it displays a client-selection menu. With no client in a noninteractive invocation, it prints usage and exits nonzero. An unknown client produces a concise error followed by usage.

The dispatcher remains thin. Focused Claude and Codex launchers own their client-specific model state, arguments, environment, and process invocation. Shared modules own Janus credentials, model catalog access, health checks, common state paths, and reusable terminal selection behavior.

## Configuration and State

The default configuration root is:

```text
~/.config/janus-launcher/
├── router.conf
├── claude-mappings.conf
└── codex.conf
```

`JANUS_LAUNCHER_CONFIG_DIR` can override this root for tests and advanced use.

### Shared router configuration

`router.conf` stores:

```text
JANUS_BASE_URL=https://janus.example
JANUS_API_KEY=secret
```

At runtime, `JANUS_LAUNCHER_BASE_URL` and `JANUS_LAUNCHER_API_KEY` override corresponding file values. Both clients use these credentials and the same URL normalization, setup, health, and catalog behavior.

Configuration persistence must preserve the existing secure file-permission behavior. Missing, malformed, or unwritable configuration must produce actionable failures without printing the API key.

### Claude mappings

`claude-mappings.conf` retains:

```text
OPUS_MODEL=provider/model-id
SONNET_MODEL=provider/model-id
HAIKU_MODEL=provider/model-id
SUBAGENT_MODEL=provider/model-id
DEFAULT_TIER=sonnet
```

The launcher validates `DEFAULT_TIER` as `opus`, `sonnet`, or `haiku` and validates configured routes against the current Janus catalog. Existing legacy-file fallback behavior inside the old mapping format is out of scope because the product-level rename is a clean break; newly written files always include all mappings.

### Codex mapping

`codex.conf` stores one value:

```text
MODEL=provider/model-id
```

The Codex launcher validates this model against the current Janus catalog. If no valid persisted value exists and the terminal is interactive, it opens the shared model picker. In a noninteractive invocation that needs a model and has neither a valid persisted model nor a caller-provided model argument, it exits with a corrective error rather than prompting.

## Shared Architecture

The current Janus API helper remains the base for shared URL and catalog behavior. Additional focused modules may be extracted from the existing Claude launcher for:

- application paths and configuration loading;
- first-run Janus credential setup;
- shared dependency and health checks;
- model catalog loading and validation; and
- terminal menu primitives.

Each module must expose a narrow shell-function interface and avoid client-specific environment or state. Claude-only role mappings remain in the Claude launcher or a Claude-specific module. Codex provider construction remains in the Codex launcher or a Codex-specific module. The central dispatcher contains no API or model logic.

This division avoids duplicating setup and catalog behavior while preventing a single launcher from accumulating branches for materially different client contracts.

## Claude Launch Flow

`claude-janus` preserves the established user workflow:

1. load shared Janus credentials;
2. run first-time setup if required;
3. validate Janus health and retrieve `/v1/models`;
4. load or interactively configure all four Claude mappings;
5. select the effective default tier;
6. export Claude-specific integration variables; and
7. execute `claude` with the user's arguments.

The child environment includes:

- `ANTHROPIC_BASE_URL`;
- `ANTHROPIC_AUTH_TOKEN`;
- an empty `ANTHROPIC_API_KEY`;
- `ANTHROPIC_DEFAULT_OPUS_MODEL`;
- `ANTHROPIC_DEFAULT_SONNET_MODEL`;
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`; and
- `CLAUDE_CODE_SUBAGENT_MODEL`.

These names are part of Claude Code's integration contract and are not renamed. The launcher unsets conflicting model state as it does today.

Existing behavior for a caller-supplied model, help and version requests, dry runs, executable resolution, `exec`, exit codes, and signal propagation must remain covered by regression tests.

## Codex Launch Flow

`codex-janus` performs this sequence:

1. load shared Janus credentials;
2. run shared first-time setup if required;
3. validate Janus health and retrieve `/v1/models`;
4. load a valid model from `codex.conf`, accept a caller-provided model, or interactively select and persist a model;
5. expose the Janus API key to the child through a launcher-owned environment variable; and
6. execute `codex` with temporary Janus provider overrides and the user's arguments.

The invocation is equivalent to:

```bash
JANUS_LAUNCHER_CODEX_API_KEY="$JANUS_API_KEY" codex \
  -c 'model_provider="janus"' \
  -c 'model_providers.janus.name="Janus"' \
  -c 'model_providers.janus.base_url="<normalized Janus /v1 URL>"' \
  -c 'model_providers.janus.env_key="JANUS_LAUNCHER_CODEX_API_KEY"' \
  -c 'model_providers.janus.wire_api="responses"' \
  --model '<selected-model>' \
  "$@"
```

The implementation must quote generated TOML values correctly even when a URL or model identifier contains shell- or TOML-significant characters. It must not place the secret itself in process arguments.

Current Codex accepts only the Responses wire API for custom providers. It appends `/responses` to the normalized `/v1` base URL, so Janus must expose `POST /v1/responses`. A Chat-Completions-only Janus deployment is unsupported. The launcher will not translate protocols.

If the user supplies `--model VALUE`, `--model=VALUE`, `-m VALUE`, or the supported attached short form, that model wins and the launcher does not append its stored model. A caller-supplied model is validated against the retrieved Janus catalog just like a persisted or interactively selected model; an unadvertised model produces an actionable error. The temporary provider selection and provider definition still apply so the request goes through Janus. Other Codex options, prompts, and subcommands pass through unchanged.

The wrapper does not edit `~/.codex/config.toml`, does not require a named Codex profile, and does not require OpenAI account login because the selected custom provider reads `JANUS_LAUNCHER_CODEX_API_KEY`.

## Health and Compatibility Validation

Shared launch validation requires a healthy Janus service and a nonempty model catalog. The launcher documents that Codex additionally requires a Responses-compatible Janus deployment, but the first release does not probe `/v1/responses`: a generation probe could be billable or stateful, and Janus currently exposes no defined non-destructive capability contract. If the endpoint is absent or incompatible, Codex's request failure is preserved unchanged.

All catalog entries are offered to both clients. The first release does not infer compatibility from provider or model names and does not consume undefined capability metadata.

## Argument Handling and Process Semantics

Dedicated launchers pass unrelated arguments unchanged and finish with `exec` so child exit codes and signals propagate naturally.

Each launcher recognizes only the arguments needed to avoid conflicting defaults. Parsing must account for long-option assignment forms and avoid mistaking values belonging to unrelated options for a model. Top-level `-h`, `--help`, `-V`, and `--version`, as well as a top-level `help` subcommand, bypass credential setup, health checks, catalog loading, and model selection and execute the client directly. All other subcommands use the normal Janus launch flow; their argument vectors remain unchanged apart from launcher-owned provider overrides and a default model when needed.

Provider overrides owned by Janus Launcher are authoritative for `codex-janus`. Because Codex global overrides must precede some subcommands, launcher-owned overrides remain before the caller's argument vector. The launcher rejects caller `-c` or `--config` assignments to `model_provider` or any `model_providers.janus` key with an actionable error, while passing unrelated configuration overrides unchanged. This prevents later caller arguments from replacing the Janus routing contract.

## Errors and Secret Handling

Launchers provide explicit failures for:

- missing shared dependencies such as `curl` or `jq`;
- a missing selected client executable;
- invalid, incomplete, or unwritable configuration;
- failed Janus health checks;
- an empty or malformed model catalog;
- configured models no longer advertised by Janus;
- a Codex Responses request rejected by the configured Janus deployment, preserving Codex's diagnostic;
- missing model state in noninteractive use; and
- unknown dispatcher clients or malformed client selection.

The API key must not appear in generated arguments, dry-run output, diagnostics, or test snapshots. Dry-run output may name `JANUS_LAUNCHER_CODEX_API_KEY` but must redact its value. Configuration files remain user-readable only.

## Installation

`install.sh` installs:

```text
~/.local/bin/janus-launcher
~/.local/bin/claude-janus
~/.local/bin/codex-janus
```

Shared libraries are installed under the renamed Janus Launcher data location. The installer initializes `~/.config/janus-launcher` securely when necessary and does not overwrite valid new-format configuration without confirmation. It does not migrate the legacy directory.

Installer output and update/uninstall guidance use the new product and repository identity. Required dependencies distinguish shared tools from client-specific executables, allowing installation even if only one client is currently present while reporting missing executables when that client is launched.

## Testing Strategy

### Shared tests

Tests cover:

- base URL normalization and `/v1` construction;
- runtime-over-file credential precedence;
- `/v1/health` and `/v1/models` validation;
- the new config root and environment names;
- secure persistence;
- malformed and unwritable configuration; and
- model catalog loading and validation.

### Claude regression tests

Tests preserve coverage for:

- four independent mappings;
- default-tier selection;
- Anthropic environment exports and conflict cleanup;
- caller-supplied models;
- help, version, and dry-run behavior;
- executable resolution and passthrough; and
- pseudo-TTY menu interactions.

### Codex tests

Tests cover:

- first-run single-model selection and persistence;
- valid persisted loading and stale-model recovery;
- noninteractive missing-model failure;
- exact temporary provider overrides;
- the Responses API wire contract and normalized base URL;
- key delivery only through `JANUS_LAUNCHER_CODEX_API_KEY`;
- `-m` and `--model` forms and precedence;
- unrelated configuration override passthrough;
- interactive mode, prompts, and Codex subcommands;
- dry-run redaction;
- missing executable errors; and
- passthrough of Codex endpoint incompatibility diagnostics.

Mocks capture the final child environment and argument vector without making generation requests.

### Dispatcher and installer tests

Tests cover:

- explicit Claude and Codex delegation;
- argument preservation;
- interactive client selection;
- noninteractive usage failure;
- unknown clients;
- installation of all commands and shared libraries;
- executable permissions; and
- new-path initialization without legacy migration.

Automated pseudo-TTY tests remain for menu behavior and are extended only where direct shell tests cannot validate terminal interaction.

## Documentation

The active README and maintainer guidance explain:

- Janus Launcher's multi-client purpose;
- installation from `amanverasia/janus-launcher`;
- all three command forms;
- Claude's four role mappings;
- Codex's single model mapping;
- the mandatory Codex Responses API contract;
- configuration files and environment precedence;
- the clean-break upgrade procedure;
- dependencies and troubleshooting; and
- how client arguments pass through.

Active badges, links, user-agent strings, and repository references use the new identity. Historical records are not rewritten unless users would otherwise follow them as current instructions.

## Acceptance Criteria

The implementation is complete when a fresh installation can:

1. configure one Janus connection shared by both clients;
2. launch Claude Code with independent Opus, Sonnet, Haiku, and subagent mappings;
3. launch Codex with one selected Janus model through `POST /v1/responses`;
4. perform both operations through either dedicated commands or the central dispatcher;
5. preserve unrelated user arguments, exit codes, and signals;
6. fail noninteractively rather than prompt when required input is missing;
7. install all commands and libraries under the new product identity;
8. pass all shell and pseudo-TTY tests; and
9. expose no API key in child arguments, dry runs, or diagnostics.
