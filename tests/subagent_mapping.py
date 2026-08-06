#!/usr/bin/env python3
"""Pseudo-TTY regression test for independent subagent mapping configuration."""
import os
import pty
import re
import select
import sys
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tmp = Path(tempfile.mkdtemp(prefix="claude-janus-subagent-test-"))
(tmp / "bin").mkdir()
(tmp / "config" / "janus-launcher").mkdir(parents=True)
(tmp / "config" / "janus-launcher" / "claude-mappings.conf").write_text(
    "OPUS_MODEL=openrouter/anthropic/claude-opus-4.8\n"
    "SONNET_MODEL=deepseek/deepseek-v4-pro\n"
    "HAIKU_MODEL=zhipu/glm-4.7\n"
    "SUBAGENT_MODEL=deepseek/deepseek-v4-pro\n"
    "DEFAULT_TIER=sonnet\n"
)

fake_claude = tmp / "bin" / "claude"
fake_claude.write_text(
    "#!/usr/bin/env bash\n"
    "printf 'ARGS:'; printf ' <%s>' \"$@\"; echo\n"
    "printf 'SUBAGENT=%s\\n' \"$CLAUDE_CODE_SUBAGENT_MODEL\"\n"
)
fake_claude.chmod(0o755)

fake_curl = tmp / "bin" / "curl"
fake_curl.write_text(
    "#!/usr/bin/env bash\n"
    "for arg in \"$@\"; do\n"
    "  [[ \"$arg\" == */v1/health ]] && exit 0\n"
    "  [[ \"$arg\" == */v1/models ]] && printf '%s\\n' '{\"data\":[{\"id\":\"openrouter/anthropic/claude-opus-4.8\"},{\"id\":\"deepseek/deepseek-v4-pro\"},{\"id\":\"deepseek/deepseek-v4-flash\"},{\"id\":\"zhipu/glm-4.7\"}]}' && exit 0\n"
    "done\nexit 7\n"
)
fake_curl.chmod(0o755)

env = os.environ.copy()
env.update(
    PATH=f"{tmp / 'bin'}:/usr/bin:/bin",
    JANUS_LAUNCHER_CONFIG_DIR=str(tmp / "config" / "janus-launcher"),
    JANUS_LAUNCHER_BASE_URL="https://router.example",
    JANUS_LAUNCHER_API_KEY="test-key",
    TERM="xterm-256color",
)

pid, fd = pty.fork()
if pid == 0:
    os.execve(str(root / "bin" / "claude-janus"), ["claude-janus"], env)

buffer = bytearray()


def wait_for(needle: bytes, timeout: float = 8) -> None:
    end = time.time() + timeout
    while time.time() < end:
        if needle in buffer:
            return
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                break
            buffer.extend(data)
    raise RuntimeError(f"did not see {needle!r}")


def wait_for_after(needle: bytes, offset: int, timeout: float = 8) -> None:
    end = time.time() + timeout
    while time.time() < end:
        if needle in buffer[offset:]:
            return
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                break
            buffer.extend(data)
    raise RuntimeError(f"did not see a new {needle!r}")


def press(key: bytes, pause: float = 0.15) -> None:
    os.write(fd, key)
    time.sleep(pause)


wait_for(b"Esc/Q cancel")
press(b"c")
wait_for(b"Change subagent mapping")
press(b"a")
wait_for(b"Enter another exact Janus model ID")
press(b"f")
wait_for(b"Mapping saved")
press(b" ")
wait_for(b"Change subagent mapping")
before_exit = len(buffer)
press(b"\x1b")
wait_for_after(b"START SESSION", before_exit)
press(b"\r")

end = time.time() + 8
status = None
while time.time() < end:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            data = os.read(fd, 65536)
            if data:
                buffer.extend(data)
        except OSError:
            pass
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        break
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)

for _ in range(20):
    ready, _, _ = select.select([fd], [], [], 0.05)
    if not ready:
        break
    try:
        buffer.extend(os.read(fd, 65536))
    except OSError:
        break

raw = bytes(buffer)
text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", raw).decode("utf-8", "replace")
mappings = tmp / "config" / "janus-launcher" / "claude-mappings.conf"
mapping_text = mappings.read_text() if mappings.exists() else ""
checks = {
    "configuration action": "Change subagent mapping" in text,
    "primary launch remains Sonnet": "ARGS: <--model> <sonnet>" in text,
    "selected subagent exported": "SUBAGENT=deepseek/deepseek-v4-flash" in text,
    "selected subagent persisted": "SUBAGENT_MODEL=deepseek/deepseek-v4-flash\n" in mapping_text,
    "all mappings persisted": all(
        f"{key}=" in mapping_text
        for key in ("OPUS_MODEL", "SONNET_MODEL", "HAIKU_MODEL", "DEFAULT_TIER")
    ),
    "never launches subagent tier": "<--model> <subagent>" not in text,
    "no escaped arrows": all(token not in text for token in ("^[[A", "^[[B", "^[[C", "^[[D")),
    "success": os.waitstatus_to_exitcode(status) == 0,
}
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if not all(checks.values()):
    print(text)
    print(mapping_text)
    sys.exit(1)
