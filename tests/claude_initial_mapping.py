#!/usr/bin/env python3
"""Pseudo-TTY regression for fresh Claude mappings from a non-curated catalog."""
import os
import pty
import re
import select
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="janus-claude-initial-mapping-"))
BIN = TMP / "bin"
CONFIG = TMP / "config"
BIN.mkdir()
CONFIG.mkdir()
CATALOG = '{"data":[{"id":"catalog/one"},{"id":"catalog/two"},{"id":"catalog/three"},{"id":"catalog/four"}]}'

(BIN / "curl").write_text(
    "#!/usr/bin/env bash\n"
    "for arg in \"$@\"; do\n"
    "  [[ \"$arg\" == */v1/health ]] && exit 0\n"
    f"  [[ \"$arg\" == */v1/models ]] && printf '%s\\n' '{CATALOG}' && exit 0\n"
    "done\nexit 7\n"
)
(BIN / "curl").chmod(0o755)
(BIN / "claude").write_text(
    "#!/usr/bin/env bash\n"
    "printf 'ARGS:'; printf ' <%s>' \"$@\"; echo\n"
    "printf 'MAPPINGS=%s|%s|%s|%s\\n' \"$ANTHROPIC_DEFAULT_OPUS_MODEL\" \"$ANTHROPIC_DEFAULT_SONNET_MODEL\" \"$ANTHROPIC_DEFAULT_HAIKU_MODEL\" \"$CLAUDE_CODE_SUBAGENT_MODEL\"\n"
)
(BIN / "claude").chmod(0o755)

env = os.environ.copy()
env.update(
    PATH=f"{BIN}:/usr/bin:/bin",
    HOME=str(TMP / "home"),
    JANUS_LAUNCHER_CONFIG_DIR=str(CONFIG),
    JANUS_LAUNCHER_BASE_URL="https://router.example",
    JANUS_LAUNCHER_API_KEY="test-key",
    TERM="xterm-256color",
)
pid, fd = pty.fork()
if pid == 0:
    os.execve(str(ROOT / "bin" / "claude-janus"), ["claude-janus"], env)

raw = bytearray()
transcript = bytearray()


def wait_for(needle: bytes, timeout: float = 8) -> None:
    deadline = time.time() + timeout
    while needle not in raw and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                raw.extend(chunk)
                transcript.extend(chunk)
            except OSError:
                break
    if needle not in raw:
        raise RuntimeError(f"did not see {needle!r}: {bytes(transcript)!r}")


wait_for(b"Initial Claude mapping setup")
for index, role in enumerate((b"Map the Opus model", b"Map the Sonnet model", b"Map the Haiku model", b"Map the Subagent model")):
    wait_for(role)
    os.write(fd, b"\r")
    time.sleep(0.12)
    wait_for(b"Press any key to continue")
    os.write(fd, b" ")
    time.sleep(0.12)
    if index < 3:
        del raw[:]
wait_for(b"Choose a Claude Code tier")
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
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw.extend(chunk)
            transcript.extend(chunk)
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
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        raw.extend(chunk)
    except OSError:
        break

text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", bytes(transcript)).decode("utf-8", "replace")
state = CONFIG / "claude-mappings.conf"
state_text = state.read_text() if state.exists() else ""
checks = {
    "fresh setup offered": "Initial Claude mapping setup" in text,
    "all four roles offered": all(f"Map the {role} model" in text for role in ("Opus", "Sonnet", "Haiku", "Subagent")),
    "only catalog model persisted": state_text == (
        "OPUS_MODEL=catalog/one\nSONNET_MODEL=catalog/one\nHAIKU_MODEL=catalog/one\n"
        "SUBAGENT_MODEL=catalog/one\nDEFAULT_TIER=sonnet\n"
    ),
    "validated mappings launched": "MAPPINGS=catalog/one|catalog/one|catalog/one|catalog/one" in text,
    "success": os.waitstatus_to_exitcode(status) == 0,
}
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if not all(checks.values()):
    print(text)
    print(state_text)
    raise SystemExit(1)
