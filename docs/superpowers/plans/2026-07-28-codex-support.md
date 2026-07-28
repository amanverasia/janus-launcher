# Janus Launcher Codex Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the product to Janus Launcher and add a dispatcher plus a Codex launcher that routes current Codex CLI traffic through Janus's Responses API without regressing Claude Code support.

**Architecture:** A thin `janus-launcher` dispatcher delegates to focused `claude-janus` and `codex-janus` executables. Shared Bash libraries own Janus API access, clean-break configuration, runtime validation, and terminal primitives; each client owns its mapping schema, argument parsing, and child-process contract.

**Tech Stack:** Bash 4+, curl, jq, Python 3 standard-library pseudo-terminals, GitHub Actions.

## Global Constraints

- Use `~/.config/janus-launcher` by default and never read or migrate `~/.config/claude-janus`.
- Honor `JANUS_LAUNCHER_CONFIG_DIR`, `JANUS_LAUNCHER_BASE_URL`, and `JANUS_LAUNCHER_API_KEY`; do not honor legacy `CLAUDE_JANUS_*`, `JANUS_BASE_URL`, or `JANUS_API_KEY` as launcher overrides.
- Install `janus-launcher`, `claude-janus`, and `codex-janus` and shared data under `${XDG_DATA_HOME:-$HOME/.local/share}/janus-launcher`.
- Preserve Claude's Opus, Sonnet, Haiku, and subagent mappings.
- Persist exactly one Codex model and configure Codex with temporary `-c` overrides using `wire_api="responses"` and `<normalized-base>/v1`.
- Do not edit `~/.codex/config.toml`, create Codex profiles, bundle a protocol translator, or probe `/v1/responses` with a generation request.
- Never include the Janus API key in child arguments, dry-run output, or diagnostics.
- Build child commands with Bash arrays and end real launches with `exec` so arguments, signals, and exit status are preserved.
- Follow test-driven development: observe each new test fail before adding its implementation.

## File Structure

### Create

- `lib/janus_config.sh` — paths, router parsing, precedence, secure persistence, and first-run setup.
- `lib/janus_runtime.sh` — dependency checks, executable resolution, top-level passthrough detection, and service orchestration.
- `lib/janus_ui.sh` — shared terminal state, navigation, rendering primitives, and restoration traps.
- `bin/codex-janus` — Codex model state, argument validation, provider overrides, and execution.
- `bin/janus-launcher` — client dispatcher and interactive client picker.
- `tests/test_janus_config.sh` — clean-break configuration tests.
- `tests/test_janus_runtime.sh` — dependencies, bypass semantics, and executable lookup tests.
- `tests/test_janus_ui.sh` — non-PTY UI primitive tests.
- `tests/test_claude_launcher.sh` — migrated Claude process-contract regression tests.
- `tests/test_codex_launcher.sh` — Codex state, arguments, provider, redaction, and process tests.
- `tests/test_dispatcher.sh` — dispatcher delegation and argument-vector tests.
- `tests/test_install.sh` — installed layout and clean-break installer tests.
- `tests/codex_model_selection.py` — Codex model-picker PTY test.
- `tests/dispatcher_selection.py` — dispatcher client-picker PTY test.

### Modify

- `lib/janus_api.sh` — validated catalog and service API with Janus Launcher identity.
- `bin/claude-janus` — consume shared modules and use new config/environment names.
- `install.sh` — install all commands and libraries into new paths.
- `config.example` — Janus Launcher router template.
- `tests/run.sh` — execute the expanded suite.
- `tests/smoke.sh` — remove cases moved into focused suites; delete if no unique case remains.
- `tests/arrow_keys.py` — new paths and environment names.
- `tests/subagent_mapping.py` — new paths and environment names.
- `README.md` — multi-client usage and clean-break upgrade guide.
- `CLAUDE.md` — new architecture and development commands.

---

### Task 1: Generalize and Validate the Janus API Boundary

**Files:**
- Modify: `lib/janus_api.sh:1-48`
- Modify: `tests/test_janus_api.sh:1-60`
- Use: `tests/fixtures/models_openai.json`
- Use: `tests/fixtures/models_anthropic.json`
- Use: `tests/fixtures/models_empty.json`

**Interfaces:**
- Produces: `janus_normalize_base_url URL` prints a base without trailing slash or `/v1`.
- Produces: `janus_api_root URL` prints `<normalized-base>/v1`.
- Produces: `janus_catalog_validate_json JSON` accepts only an object with an array-valued `.data` and string `.data[].id` values.
- Produces: `janus_extract_model_ids JSON` prints one model ID per line and fails on malformed structure.
- Produces: `janus_catalog_contains JSON MODEL_ID` returns success only for an exact ID.
- Produces: `janus_fetch_catalog BASE_URL API_KEY` prints the models response.
- Produces: `janus_validate_service BASE_URL API_KEY` performs health then one catalog fetch, prints validated nonempty catalog JSON, and returns `1` for health failure, `2` for catalog transport failure, `3` for malformed catalog, `4` for empty catalog, or `127` for a missing dependency.

- [ ] **Step 1: Add failing URL, schema, and service-contract tests**

Extend `tests/test_janus_api.sh` with table-driven URL checks and malformed payload assertions:

```bash
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

for case in \
  'https://janus.test|https://janus.test/v1' \
  'https://janus.test/|https://janus.test/v1' \
  'https://janus.test/v1|https://janus.test/v1' \
  'https://janus.test/v1/|https://janus.test/v1'
do
  IFS='|' read -r input expected <<<"$case"
  assert_eq "$(janus_api_root "$input")" "$expected" "api root for $input"
done

! janus_catalog_validate_json 'not-json'
! janus_catalog_validate_json '{}'
! janus_catalog_validate_json '{"data":{}}'
! janus_catalog_validate_json '{"data":[{"id":7}]}'
janus_catalog_validate_json '{"data":[{"id":"provider/model"}]}'
```

Add a fake `curl` that records arguments and separately simulates health failure, models failure, malformed JSON, empty catalog, and success. Assert the success path calls `/v1/models` exactly once, includes `Authorization: Bearer test-key`, uses a `janus-launcher/` user agent, and never places `test-key` in a URL.

- [ ] **Step 2: Run the focused API test and verify failure**

Run:

```bash
bash tests/test_janus_api.sh
```

Expected: FAIL because `janus_api_root`, `janus_catalog_validate_json`, and `janus_validate_service` do not exist and the user agent is still `claude-janus/1.0`.

- [ ] **Step 3: Implement the minimal validated API functions**

Update `lib/janus_api.sh` around these implementations:

```bash
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
```

Use `command -v curl`/`command -v jq` checks, `janus_api_root`, `-A 'janus-launcher/1.0'`, authenticated `/models`, and one captured catalog payload in `janus_validate_service`. Keep the status mapping exact and distinguish a valid empty array from malformed JSON.

- [ ] **Step 4: Run API tests and syntax validation**

Run:

```bash
bash tests/test_janus_api.sh
bash -n lib/janus_api.sh tests/test_janus_api.sh
```

Expected: all API assertions pass and syntax checks produce no output.

- [ ] **Step 5: Commit the shared API boundary**

```bash
git add lib/janus_api.sh tests/test_janus_api.sh
git commit -m "Generalize Janus API validation"
```

---

### Task 2: Add Clean-Break Shared Configuration

**Files:**
- Create: `lib/janus_config.sh`
- Create: `tests/test_janus_config.sh`
- Modify: `tests/run.sh:1-8`

**Interfaces:**
- Consumes: `janus_normalize_base_url URL` from Task 1.
- Produces: `janus_config_init_paths` sets `JANUS_CONFIG_DIR`, `JANUS_ROUTER_CONFIG`, `JANUS_CLAUDE_MAPPINGS`, and `JANUS_CODEX_CONFIG`.
- Produces: `janus_config_load_router FILE` sets `JANUS_BASE_URL` and `JANUS_API_KEY`, with `JANUS_LAUNCHER_BASE_URL` and `JANUS_LAUNCHER_API_KEY` taking precedence.
- Produces: `janus_config_is_placeholder BASE_URL API_KEY` returns success for missing/example credentials.
- Produces: `janus_config_write_router FILE BASE_URL API_KEY` writes a normalized, mode-0600 router file under a mode-0700 directory.
- Produces: `janus_config_run_first_setup` uses `JANUS_LAUNCHER_SETUP_BASE_URL` and `JANUS_LAUNCHER_SETUP_API_KEY` for noninteractive tests or prompts interactively.

- [ ] **Step 1: Write failing path, precedence, parsing, and permission tests**

Create `tests/test_janus_config.sh` using isolated subshell cases. Include these representative assertions:

```bash
HOME="$TMP/home" XDG_CONFIG_HOME= JANUS_LAUNCHER_CONFIG_DIR= bash -c '
  source lib/janus_api.sh
  source lib/janus_config.sh
  janus_config_init_paths
  [[ "$JANUS_CONFIG_DIR" == "$HOME/.config/janus-launcher" ]]
'

JANUS_LAUNCHER_CONFIG_DIR="$TMP/custom" bash -c '
  source lib/janus_api.sh
  source lib/janus_config.sh
  janus_config_init_paths
  [[ "$JANUS_ROUTER_CONFIG" == "'$TMP'/custom/router.conf" ]]
  [[ "$JANUS_CLAUDE_MAPPINGS" == "'$TMP'/custom/claude-mappings.conf" ]]
  [[ "$JANUS_CODEX_CONFIG" == "'$TMP'/custom/codex.conf" ]]
'
```

Write a router fixture, override only one value via `JANUS_LAUNCHER_*`, and assert partial precedence. Populate legacy files and legacy environment variables with sentinel values and assert neither is loaded. Test malformed lines, duplicate keys, placeholders, directory mode `700`, file mode `600`, normalized persistence, and redacted errors.

- [ ] **Step 2: Run the configuration test and verify failure**

Run:

```bash
bash tests/test_janus_config.sh
```

Expected: FAIL because `lib/janus_config.sh` is absent.

- [ ] **Step 3: Implement strict configuration parsing and secure writes**

Create `lib/janus_config.sh` with a guarded source marker and exact-key parsing:

```bash
janus_config_init_paths() {
  JANUS_CONFIG_DIR="${JANUS_LAUNCHER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/janus-launcher}"
  JANUS_ROUTER_CONFIG="$JANUS_CONFIG_DIR/router.conf"
  JANUS_CLAUDE_MAPPINGS="$JANUS_CONFIG_DIR/claude-mappings.conf"
  JANUS_CODEX_CONFIG="$JANUS_CONFIG_DIR/codex.conf"
}
```

Parse only `JANUS_BASE_URL=` and `JANUS_API_KEY=` from `router.conf`; reject unknown non-comment lines and duplicate keys. Read the file into temporary locals, then apply launcher environment overrides. Write through a temporary file in the destination directory, set mode `600`, and atomically `mv` it into place. Never interpolate a key into an error.

- [ ] **Step 4: Add the configuration suite to the runner and verify**

Add after the API test in `tests/run.sh`:

```bash
"$ROOT/tests/test_janus_config.sh"
```

Run:

```bash
bash tests/test_janus_config.sh
bash -n lib/janus_config.sh tests/test_janus_config.sh tests/run.sh
```

Expected: all configuration cases pass.

- [ ] **Step 5: Commit shared configuration**

```bash
git add lib/janus_config.sh tests/test_janus_config.sh tests/run.sh
git commit -m "Add Janus Launcher configuration"
```

---

### Task 3: Extract Shared Runtime and Terminal Primitives

**Files:**
- Create: `lib/janus_runtime.sh`
- Create: `lib/janus_ui.sh`
- Create: `tests/test_janus_runtime.sh`
- Create: `tests/test_janus_ui.sh`
- Modify: `bin/claude-janus:16-138,212-386,470-493`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: all Task 1 API and Task 2 configuration interfaces.
- Produces: `janus_require_command COMMAND LABEL` and `janus_require_shared_dependencies`.
- Produces: `janus_resolve_client_executable NAME WRAPPER_PATH` prints a non-wrapper executable or returns `127`.
- Produces: `janus_is_top_level_passthrough "$@"` recognizes only first-position `-h`, `--help`, `-V`, `--version`, or `help`.
- Produces: `janus_load_validated_service` loads/setup config in the current shell and sets caller-visible `JANUS_BASE_URL`, `JANUS_API_KEY`, and `JANUS_CATALOG_JSON` without requiring command substitution.
- Produces UI functions `janus_ui_init`, `janus_ui_is_interactive`, `janus_ui_read_reply`, `janus_ui_tty_raw`, `janus_ui_tty_restore`, `janus_ui_read_key`, `janus_ui_navigate`, `janus_ui_clear`, `janus_ui_prepare_screen`, `janus_ui_header`, `janus_ui_pause`, `janus_ui_message`, and `janus_ui_choice`.

- [ ] **Step 1: Write failing runtime and UI unit tests**

Create `tests/test_janus_runtime.sh` with a temporary `PATH` and tests like:

```bash
janus_is_top_level_passthrough --help
janus_is_top_level_passthrough help --verbose
! janus_is_top_level_passthrough exec --help
! janus_is_top_level_passthrough -p 'explain -h'
```

Mock executable lookup and assert a wrapper named `claude-janus` cannot be returned as the `claude` child. Mock `janus_validate_service`, call `janus_load_validated_service` directly (not through `$(...)`), and assert `JANUS_BASE_URL`, `JANUS_API_KEY`, and `JANUS_CATALOG_JSON` remain set in the caller after exactly one validation call.

Create `tests/test_janus_ui.sh` to assert noninteractive detection, text-only headers with colors disabled, key-to-action decoding via redirected input, and idempotent terminal restoration.

- [ ] **Step 2: Run both new tests and verify failure**

Run:

```bash
bash tests/test_janus_runtime.sh
bash tests/test_janus_ui.sh
```

Expected: FAIL because the new shared modules do not exist.

- [ ] **Step 3: Implement runtime orchestration**

Create `lib/janus_runtime.sh` with first-argument-only passthrough logic:

```bash
janus_is_top_level_passthrough() {
  case "${1-}" in
    -h|--help|-V|--version|help) return 0 ;;
    *) return 1 ;;
  esac
}
```

Implement dependency and child resolution without `eval`. `janus_load_validated_service` must call config initialization/load/setup in the current shell, capture `janus_validate_service` output once into `JANUS_CATALOG_JSON`, and leave normalized `JANUS_BASE_URL` plus `JANUS_API_KEY` set for child-environment construction. Launchers must call this function directly rather than through command substitution, which would lose assignments in a subshell.

- [ ] **Step 4: Extract UI functions without changing Claude behavior**

Move `bin/claude-janus:212-386` into `lib/janus_ui.sh`, rename functions with the `janus_ui_` prefix, parameterize product/title text, and preserve EXIT/INT/TERM/HUP restoration. Update Claude call sites to source the shared libraries from checkout-relative `lib/` or `${XDG_DATA_HOME:-$HOME/.local/share}/janus-launcher/lib/`.

Do not yet rename Claude state paths or environment overrides; this step isolates reusable behavior only.

- [ ] **Step 5: Run focused and existing regression tests**

Run:

```bash
bash tests/test_janus_runtime.sh
bash tests/test_janus_ui.sh
bash tests/smoke.sh
python3 tests/arrow_keys.py
python3 tests/subagent_mapping.py
bash -n bin/claude-janus lib/janus_runtime.sh lib/janus_ui.sh
```

Expected: new suites and all existing Claude tests pass.

- [ ] **Step 6: Register suites and commit extraction**

Add both tests to `tests/run.sh`, then commit:

```bash
git add lib/janus_runtime.sh lib/janus_ui.sh bin/claude-janus tests/test_janus_runtime.sh tests/test_janus_ui.sh tests/run.sh
git commit -m "Extract shared launcher runtime"
```

---

### Task 4: Migrate Claude to the Janus Launcher Contract

**Files:**
- Create: `tests/test_claude_launcher.sh`
- Modify: `bin/claude-janus:29-210,470-520,766-899`
- Modify: `tests/arrow_keys.py:15-32,106-113`
- Modify: `tests/subagent_mapping.py:16-40,109-121`
- Modify: `tests/smoke.sh:1-248`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: shared config/runtime/UI interfaces from Tasks 1–3.
- Produces: `claude_valid_tier TIER`, `claude_load_mappings FILE`, `claude_validate_mappings CATALOG_JSON`, `claude_save_mappings FILE`, `claude_model_for_tier TIER`, and `claude_parse_arguments "$@"`.
- Persists: `claude-mappings.conf` with all five approved keys.
- Exports: the existing Anthropic child environment contract.

- [ ] **Step 1: Move process-contract cases into a failing focused suite**

Create `tests/test_claude_launcher.sh` with fake `claude` and `curl` commands. Migrate unique `tests/smoke.sh` cases and change expectations to:

```bash
CONFIG_DIR="$TMP/config/janus-launcher"
export JANUS_LAUNCHER_CONFIG_DIR="$CONFIG_DIR"
export JANUS_LAUNCHER_BASE_URL='https://janus.test'
export JANUS_LAUNCHER_API_KEY='test-key'
```

Assert all four mapped routes exist in the catalog, stale mappings fail, caller `--model VALUE` and `--model=VALUE` win, and bare `--model` fails. Add strict mapping fixtures for a missing key, duplicate key, unknown non-comment line, invalid `DEFAULT_TIER`, empty model, and newline/carriage-return corruption. Cover top-level `-h`, `--help`, `-V`, `--version`, and `help`; prove `exec --help`, prompt text containing `-h`, and legacy `-v` do not bypass setup. Assert the exact launcher-owned Anthropic variables, required `ANTHROPIC_MODEL`/`OPENROUTER_API_KEY` unsets, and inheritance of an unrelated environment sentinel. Assert `JANUS_LAUNCHER_DRY_RUN=1` redacts secrets, `CLAUDE_JANUS_DRYRUN` is ignored, child exit status propagates, and all other legacy state/environment sentinels are ignored.

Delete tests for legacy missing/invalid `SUBAGENT_MODEL` fallback because new files require all mappings.

- [ ] **Step 2: Run the focused Claude suite and verify failure**

Run:

```bash
bash tests/test_claude_launcher.sh
```

Expected: FAIL because the launcher still uses legacy paths and variables.

- [ ] **Step 3: Replace embedded shared configuration and rename Claude functions**

Use `JANUS_CLAUDE_MAPPINGS` from `janus_config_init_paths`. Rename generic mapping helpers to `claude_*`, require all mapping keys exactly once, validate every route with `janus_catalog_contains`, and save all five keys with mode `600`.

Remove reads of `CLAUDE_JANUS_CONFIG`, `CLAUDE_JANUS_SETUP_*`, `CLAUDE_JANUS_TIER`, `CLAUDE_JANUS_SKIP_CHECK`, `CLAUDE_JANUS_DRYRUN`, and old directories. Standardize dry runs for both clients on `JANUS_LAUNCHER_DRY_RUN=1`. If a noninteractive tier override remains useful, name it `JANUS_LAUNCHER_CLAUDE_TIER` and validate it with `claude_valid_tier`.

- [ ] **Step 4: Apply the new runtime and argument contract**

Before shared setup, directly execute the resolved Claude child for top-level passthrough requests. For generation launches, load the validated catalog once, validate mappings and caller model, build the child array, export the approved Anthropic variables, redact dry runs, and `exec`.

Preserve existing primary-tier menu behavior and independent subagent selection.

- [ ] **Step 5: Update both Claude PTY regressions**

Change both Python tests to use `JANUS_LAUNCHER_CONFIG_DIR`, `JANUS_LAUNCHER_BASE_URL`, and `JANUS_LAUNCHER_API_KEY`. Supply a fake successful health/catalog response instead of a legacy skip flag. Change persisted path expectations to `claude-mappings.conf`.

- [ ] **Step 6: Run Claude and full shared regressions**

Run:

```bash
bash tests/test_claude_launcher.sh
python3 tests/arrow_keys.py
python3 tests/subagent_mapping.py
bash tests/test_janus_api.sh
bash tests/test_janus_config.sh
bash tests/test_janus_runtime.sh
bash tests/test_janus_ui.sh
bash -n bin/claude-janus tests/test_claude_launcher.sh
```

Expected: all pass; no active test references `~/.config/claude-janus` except assertions proving it is ignored.

- [ ] **Step 7: Recompose the runner and commit Claude migration**

Remove migrated cases from `tests/smoke.sh`; delete it if no unique assertion remains. Add `test_claude_launcher.sh` to `tests/run.sh`.

```bash
git add bin/claude-janus tests/test_claude_launcher.sh tests/arrow_keys.py tests/subagent_mapping.py tests/smoke.sh tests/run.sh
git commit -m "Migrate Claude launcher configuration"
```

---

### Task 5: Add Codex Provider and Argument Handling

**Files:**
- Create: `bin/codex-janus`
- Create: `tests/test_codex_launcher.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: shared API/config/runtime interfaces from Tasks 1–3.
- Produces: `toml_quote_string VALUE`.
- Produces: `codex_parse_arguments "$@"` setting `CODEX_CALLER_MODEL`, `CODEX_HAS_CALLER_MODEL`, `CODEX_PASSTHROUGH_ONLY`, and `CODEX_USER_ARGS`.
- Produces: `codex_validate_config_overrides "$@"` rejecting `model_provider` and `model_providers.janus[.*]` assignments.
- Produces: `codex_build_provider_arguments API_ROOT` setting `CODEX_PROVIDER_ARGS`.
- Produces: `codex_build_command CODEX_BIN MODEL "$@"` setting `CODEX_COMMAND`.

- [ ] **Step 1: Write failing tests for model forms and provider ownership**

Create a fake Codex executable that prints each argument on its own indexed line and prints whether `JANUS_LAUNCHER_CODEX_API_KEY` is set. Add cases for:

```text
--model model-a
--model=model-a
-m model-a
-mmodel-a
```

Assert there is exactly one effective model, the five Janus provider fields are present, the base URL is normalized to `/v1`, `wire_api` is `responses`, the key value is absent from argv, and unrelated `-c 'features.example=true'` remains unchanged.

Reject owned assignments in each verified Codex form: `-c KEY=VALUE`, `--config KEY=VALUE`, and `--config=KEY=VALUE`; also cover `-c=KEY=VALUE` only if the installed/target Codex parser accepts that form. Reject a missing value for separated `-c`/`--config`. Extract keys only from values associated with these options, so prompts or subcommand arguments resembling `model_provider=...` remain ordinary arguments. Add URLs/models containing spaces, quotes, backslashes, dollar signs, backticks, and semicolons and assert no element is split or executed.

- [ ] **Step 2: Run Codex tests and verify failure**

Run:

```bash
bash tests/test_codex_launcher.sh
```

Expected: FAIL because `bin/codex-janus` is absent.

- [ ] **Step 3: Implement TOML quoting and argument parsing**

Create `bin/codex-janus` with shared-library resolution matching Claude. Implement TOML basic-string escaping without `eval`:

```bash
toml_quote_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}
```

Parse argument indices into arrays. A missing model or configuration value is an error. For `-c KEY=VALUE`, `--config KEY=VALUE`, and `--config=KEY=VALUE`, inspect only the associated configuration value and split its key at the first `=`. Reject only when that key is exactly `model_provider`, exactly `model_providers.janus`, or starts with `model_providers.janus.`. Preserve unrelated options, prompts, and subcommand arguments byte-for-byte.

- [ ] **Step 4: Build authoritative temporary provider arguments**

Construct array elements equivalent to:

```bash
CODEX_PROVIDER_ARGS=(
  -c 'model_provider="janus"'
  -c 'model_providers.janus.name="Janus"'
  -c "model_providers.janus.base_url=$(toml_quote_string "$api_root")"
  -c 'model_providers.janus.env_key="JANUS_LAUNCHER_CODEX_API_KEY"'
  -c 'model_providers.janus.wire_api="responses"'
)
```

Place these before caller arguments because Codex global configuration precedes subcommands; reject caller conflicts so later arguments cannot override Janus routing. Export the key only in the child environment.

- [ ] **Step 5: Run argument/security tests and syntax checks**

Run:

```bash
bash tests/test_codex_launcher.sh
bash -n bin/codex-janus tests/test_codex_launcher.sh
```

Expected: all provider, quoting, conflict, model-form, and secret-containment assertions pass.

- [ ] **Step 6: Register and commit the Codex invocation layer**

```bash
git add bin/codex-janus tests/test_codex_launcher.sh tests/run.sh
git commit -m "Add Codex Janus provider invocation"
```

---

### Task 6: Add Codex Model Persistence and Interactive Selection

**Files:**
- Modify: `bin/codex-janus`
- Modify: `tests/test_codex_launcher.sh`
- Create: `tests/codex_model_selection.py`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `JANUS_CODEX_CONFIG`, validated catalog JSON, and shared UI functions.
- Produces: `codex_load_model FILE`, `codex_save_model FILE MODEL`, `codex_validate_model CATALOG MODEL`, and `codex_select_model CATALOG`.
- Persists: exactly one `MODEL=provider/model-id` line at mode `600`.

- [ ] **Step 1: Add failing persistence and noninteractive tests**

Extend the shell suite to cover valid, missing, malformed, duplicate, and stale `MODEL` entries. Assert caller models take precedence over stale persisted state but remain catalog-validated. Assert noninteractive missing/stale state exits nonzero without reading stdin. Reject model IDs containing newline or carriage return. Test an escaped `\u0000` catalog ID at the JSON-validation boundary and reject it before extraction because Bash variables and argv cannot represent NUL. Allow ordinary catalog IDs including slashes, dots, colons, dashes, underscores, spaces, and `=` when unambiguous; state parsing must split `MODEL=` only at the first `=` and round-trip the remainder exactly.

- [ ] **Step 2: Add a failing Codex model-picker PTY test**

Create `tests/codex_model_selection.py` following the existing `pty.fork()` pattern. Its fake `curl` returns healthy status and `models_openai.json`; fake `codex` prints indexed arguments and key-presence only. Drive the picker with arrow keys and Enter, then assert:

```python
checks = {
    "model persisted": "MODEL=deepseek/deepseek-v4-pro" in config_text,
    "model launched": expected_model_argument in output,
    "secret hidden": api_key not in output,
    "terminal clean": "\x1b[A" not in output and "\x1b[B" not in output,
}
```

Run a second process with a stale saved model and verify recovery selection.

- [ ] **Step 3: Run new model-state tests and verify failure**

Run:

```bash
bash tests/test_codex_launcher.sh
python3 tests/codex_model_selection.py
```

Expected: FAIL because state loading and the picker are not implemented.

- [ ] **Step 4: Implement strict Codex state and selection**

Parse exactly one `MODEL=` key, validate it against the cached catalog, and write atomically with mode `600`. If a caller supplied a valid catalog model, do not require or rewrite persisted state. If persisted state is missing/stale and UI is interactive, render catalog IDs with shared navigation and persist the selection. Otherwise print a corrective command-oriented error and exit nonzero.

- [ ] **Step 5: Verify shell and PTY flows**

Run:

```bash
bash tests/test_codex_launcher.sh
python3 tests/codex_model_selection.py
python3 tests/arrow_keys.py
python3 tests/subagent_mapping.py
```

Expected: Codex picker and both Claude menus pass with terminal restoration.

- [ ] **Step 6: Register PTY coverage and commit model selection**

```bash
git add bin/codex-janus tests/test_codex_launcher.sh tests/codex_model_selection.py tests/run.sh
git commit -m "Add Codex model selection"
```

---

### Task 7: Complete Codex Passthrough and Process Semantics

**Files:**
- Modify: `bin/codex-janus`
- Modify: `tests/test_codex_launcher.sh`

**Interfaces:**
- Consumes: `janus_is_top_level_passthrough`, `janus_resolve_client_executable`, and all Codex interfaces from Tasks 5–6.
- Produces: complete executable behavior for direct passthrough, Janus launches, dry runs, and error propagation.

- [ ] **Step 1: Add failing bypass and child-process tests**

Add exact cases for `-h`, `--help`, `-V`, `--version`, and `help --verbose` proving no config read and no `curl` invocation. Prove `exec --help` takes the full Janus flow. Add fake child exits, stderr markers, absent Codex, unchanged `~/.codex/config.toml`, absence of generated `--profile`, dry-run redaction, and a curl log assertion that only `/v1/health` and `/v1/models` are contacted.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
bash tests/test_codex_launcher.sh
```

Expected: FAIL on unimplemented bypass/dry-run/process cases.

- [ ] **Step 3: Implement top-level bypass and full launch ordering**

Resolve the real `codex` executable first. For passthrough requests, `exec "$CODEX_BIN" "$@"` immediately. For all other requests:

1. reject owned config overrides and parse a caller model;
2. load/setup router configuration;
3. health-check and retrieve one catalog;
4. validate/select the model;
5. build provider and child arrays;
6. export `JANUS_LAUNCHER_CODEX_API_KEY`;
7. print a redacted dry run when `JANUS_LAUNCHER_DRY_RUN=1`; otherwise `exec` the array.

Do not unset or rewrite unrelated user environment globally; the custom provider must authenticate exclusively through its configured env key.

- [ ] **Step 4: Run complete Codex and shared suites**

Run:

```bash
bash tests/test_codex_launcher.sh
python3 tests/codex_model_selection.py
bash tests/test_janus_api.sh
bash tests/test_janus_config.sh
bash tests/test_janus_runtime.sh
bash tests/test_janus_ui.sh
bash -n bin/codex-janus
```

Expected: all pass, fake child statuses propagate, and endpoint diagnostics are unchanged.

- [ ] **Step 5: Commit complete Codex process behavior**

```bash
git add bin/codex-janus tests/test_codex_launcher.sh
git commit -m "Complete Codex launcher behavior"
```

---

### Task 8: Add Dispatcher, Installer, Documentation, and End-to-End Verification

**Files:**
- Create: `bin/janus-launcher`
- Create: `tests/test_dispatcher.sh`
- Create: `tests/dispatcher_selection.py`
- Create: `tests/test_install.sh`
- Modify: `install.sh:1-41`
- Modify: `config.example:1-6`
- Modify: `tests/run.sh`
- Modify: `README.md:1-192`
- Modify: `CLAUDE.md:1-166`
- Modify: `.github/workflows/test.yml` only if the test command changes

**Interfaces:**
- Consumes: dedicated launchers and shared UI.
- Produces: `janus-launcher claude|codex [arguments...]` and an interactive no-argument client picker.
- Installs: three mode-0755 executables and four mode-0644 libraries.

- [ ] **Step 1: Write failing dispatcher tests**

Create fake sibling `claude-janus` and `codex-janus` commands that print indexed argv and exit a requested status. Test explicit delegation, removal of only the client token, preservation of empty/spaced/glob/quote arguments, exit propagation, unknown-client usage, noninteractive no-client failure, missing launcher status `127`, and absence of Janus network/config activity in the dispatcher.

- [ ] **Step 2: Add a failing interactive dispatcher PTY test**

Create `tests/dispatcher_selection.py` with fake dedicated launchers. Select Claude and Codex in separate runs, verify exact delegation, then exercise cancellation and assert terminal restoration/no leaked escape sequences.

- [ ] **Step 3: Implement the thin dispatcher**

Create `bin/janus-launcher` using sibling-command resolution first and installed `PATH` resolution second. Use an argument array and direct `exec`. For no arguments, require an interactive terminal and use `janus_ui_navigate` over exactly `Claude Code` and `Codex`; otherwise print:

```text
Usage: janus-launcher {claude|codex} [arguments...]
```

The dispatcher must not source config/API modules or contact Janus.

- [ ] **Step 4: Run dispatcher tests**

Run:

```bash
bash tests/test_dispatcher.sh
python3 tests/dispatcher_selection.py
bash -n bin/janus-launcher tests/test_dispatcher.sh
```

Expected: all explicit and interactive delegation cases pass.

- [ ] **Step 5: Write failing installer tests**

Create `tests/test_install.sh` using isolated `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `JANUS_LAUNCHER_INSTALL_DIR`. Assert:

```text
bin/janus-launcher       0755
bin/claude-janus         0755
bin/codex-janus          0755
lib/janus_api.sh          0644
lib/janus_config.sh       0644
lib/janus_runtime.sh      0644
lib/janus_ui.sh           0644
config directory          0700
router.conf               0600
```

Test idempotency, preservation of valid existing new-format router config, rejection of malformed existing config, untouched legacy config, success without either client executable installed, actionable unwritable-path failures, and new identity in output.

- [ ] **Step 6: Run installer tests and verify failure**

Run:

```bash
bash tests/test_install.sh
```

Expected: FAIL because the installer only installs Claude under legacy paths.

- [ ] **Step 7: Rewrite the installer and example configuration**

Use:

```bash
INSTALL_DIR="${JANUS_LAUNCHER_INSTALL_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${JANUS_LAUNCHER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/janus-launcher}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/janus-launcher"
```

Install all binaries and libraries with explicit modes. Create the config directory as `700`. Seed `router.conf` from the renamed `config.example` only when absent; validate rather than overwrite an existing malformed file. Do not inspect the legacy directory. Print all three installed commands and a PATH reminder.

- [ ] **Step 8: Run installer and installed-layout smoke tests**

Run:

```bash
bash tests/test_install.sh
bash -n install.sh config.example
```

Expected: installer cases pass. If `bash -n config.example` is inappropriate because it is data-only, validate it by sourcing it in an isolated subshell instead.

- [ ] **Step 9: Update active documentation**

Rewrite README usage around:

```bash
janus-launcher claude
janus-launcher codex
claude-janus
codex-janus
```

Document the three new configuration files, exact precedence variables, clean-break reconfiguration, Claude's four mappings, Codex's one mapping, `/v1/responses`, temporary provider overrides, dependency requirements, noninteractive model behavior, and passthrough semantics. Update clone/update URLs to `https://github.com/amanverasia/janus-launcher.git`.

Update `CLAUDE.md` with the new file boundaries, all focused test commands, syntax commands for all binaries/libraries, and secret-handling constraints. Leave historical design records unchanged.

- [ ] **Step 10: Recompose and run the complete test suite**

Set `tests/run.sh` to execute:

```bash
"$ROOT/tests/test_janus_api.sh"
"$ROOT/tests/test_janus_config.sh"
"$ROOT/tests/test_janus_runtime.sh"
"$ROOT/tests/test_janus_ui.sh"
"$ROOT/tests/test_claude_launcher.sh"
"$ROOT/tests/test_codex_launcher.sh"
"$ROOT/tests/test_dispatcher.sh"
"$ROOT/tests/test_install.sh"
python3 "$ROOT/tests/arrow_keys.py"
python3 "$ROOT/tests/subagent_mapping.py"
python3 "$ROOT/tests/codex_model_selection.py"
python3 "$ROOT/tests/dispatcher_selection.py"
```

Run:

```bash
./tests/run.sh
bash -n bin/janus-launcher bin/claude-janus bin/codex-janus \
  lib/janus_api.sh lib/janus_config.sh lib/janus_runtime.sh lib/janus_ui.sh \
  install.sh tests/*.sh
git diff --check
git status --short
```

Expected: every suite passes, syntax and whitespace checks are clean, and the working tree contains only intended uncommitted Task 8 changes plus this plan document before its commit.

- [ ] **Step 11: Search for stale active identity and secret hazards**

Run:

```bash
git grep -nE 'amanverasia/claude-janus|\.config/claude-janus|/share/claude-janus|XDG_DATA_HOME[^[:cntrl:]]*claude-janus|CLAUDE_JANUS_|Claude Janus' -- \
  bin lib tests install.sh config.example README.md CLAUDE.md .github
git grep -n 'JANUS_API_KEY' -- bin lib tests install.sh
```

Expected: the first search returns only deliberate clean-break assertions, if any. Review every second-search result to ensure the key is only read, persisted securely, used in an authorization header/environment assignment, or explicitly checked for redaction—never embedded into a command argument or diagnostic.

- [ ] **Step 12: Commit dispatcher, installation, and documentation**

```bash
git add bin/janus-launcher install.sh config.example tests README.md CLAUDE.md .github/workflows/test.yml \
  docs/superpowers/plans/2026-07-28-codex-support.md
git commit -m "Complete Janus Launcher Codex support"
```

- [ ] **Step 13: Perform final branch verification**

Run:

```bash
./tests/run.sh
git diff --check main...HEAD
git log --oneline main..HEAD
git status --short
git remote get-url origin
```

Expected: all tests pass; diff check and status are clean; the task commits plus design/plan commits are visible; origin is `https://github.com/amanverasia/janus-launcher.git`.
