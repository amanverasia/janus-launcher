#!/usr/bin/env python3
"""Pseudo-TTY coverage for initial and stale Codex model selection."""
import os
import pty
import re
import select
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="janus-codex-model-test-"))
BIN = TMP / "bin"
CONFIG = TMP / "config"
BIN.mkdir()
CONFIG.mkdir()
API_KEY = "pty-secret-never-print"
CATALOG = '{"data":[{"id":"openrouter/anthropic/claude-sonnet-4"},{"id":"deepseek/deepseek-v4-pro"},{"id":"combo-fast"}]}'

(BIN / "curl").write_text(
    "#!/usr/bin/env bash\n"
    "for arg in \"$@\"; do\n"
    "  [[ \"$arg\" == */v1/health ]] && exit 0\n"
    f"  [[ \"$arg\" == */v1/models ]] && printf '%s\\n' '{CATALOG}' && exit 0\n"
    "done\nexit 7\n"
)
(BIN / "curl").chmod(0o755)
(BIN / "codex").write_text(
    "#!/usr/bin/env bash\n"
    "i=0; for arg in \"$@\"; do printf 'ARG[%d]=%q\\n' \"$i\" \"$arg\"; ((i += 1)); done\n"
    "if [[ -v JANUS_LAUNCHER_CODEX_API_KEY ]]; then printf 'KEY_SET=yes\\n'; else printf 'KEY_SET=no\\n'; fi\n"
)
(BIN / "codex").chmod(0o755)


def run_picker(stale: bool) -> tuple[str, str, int]:
    state = CONFIG / "codex.conf"
    if stale:
        state.write_text("MODEL=retired/stale-model\n")
    elif state.exists():
        state.unlink()
    env = os.environ.copy()
    env.update(
        PATH=f"{BIN}:/usr/bin:/bin",
        HOME=str(TMP / "home"),
        JANUS_LAUNCHER_CONFIG_DIR=str(CONFIG),
        JANUS_LAUNCHER_BASE_URL="https://router.example/v1/",
        JANUS_LAUNCHER_API_KEY=API_KEY,
        TERM="xterm-256color",
    )
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(ROOT / "bin" / "codex-janus"), ["codex-janus", "exec", "prompt"], env)
    raw = bytearray()
    deadline = time.time() + 8
    while b"Select a Codex model" not in raw and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                raw.extend(os.read(fd, 65536))
            except OSError:
                break
    if b"Select a Codex model" in raw:
        os.write(fd, b"\x1b[B")
        time.sleep(0.12)
        os.write(fd, b"\r")
    status = None
    deadline = time.time() + 8
    while time.time() < deadline:
        got, status = os.waitpid(pid, os.WNOHANG)
        if got:
            break
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                raw.extend(os.read(fd, 65536))
            except OSError:
                pass
    if status is None:
        os.kill(pid, 9)
        _, status = os.waitpid(pid, 0)
    while True:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            break
        try:
            raw.extend(os.read(fd, 65536))
        except OSError:
            break
    text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", bytes(raw)).decode("utf-8", "replace")
    return text, state.read_text() if state.exists() else "", os.waitstatus_to_exitcode(status)


all_ok = True
for label, stale in (("initial", False), ("stale recovery", True)):
    output, config_text, exit_code = run_picker(stale)
    checks = {
        "model persisted": config_text == "MODEL=deepseek/deepseek-v4-pro\n",
        "model launched": "ARG[11]=deepseek/deepseek-v4-pro" in output,
        "secret hidden": API_KEY not in output,
        "terminal clean": "\x1b[A" not in output and "\x1b[B" not in output and "^[[" not in output,
        "key present": "KEY_SET=yes" in output,
        "success": exit_code == 0,
    }
    for name, ok in checks.items():
        print(("PASS" if ok else "FAIL"), f"{label} {name}")
    if not all(checks.values()):
        print(output)
        all_ok = False

raise SystemExit(0 if all_ok else 1)
