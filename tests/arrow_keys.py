#!/usr/bin/env python3
"""Pseudo-TTY regression test for arrow-key navigation."""
import os
import pty
import re
import select
import sys
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tmp = Path(tempfile.mkdtemp(prefix="claude-janus-arrow-test-"))
(tmp / "bin").mkdir()
(tmp / "config").mkdir()
fake = tmp / "bin" / "claude"
fake.write_text("#!/usr/bin/env bash\nprintf 'ARGS:'; printf ' <%s>' \"$@\"; echo\n")
fake.chmod(0o755)
fake_curl = tmp / "bin" / "curl"
fake_curl.write_text(
    "#!/usr/bin/env bash\n"
    "for arg in \"$@\"; do\n"
    "  [[ \"$arg\" == */v1/health ]] && exit 0\n"
    "  [[ \"$arg\" == */v1/models ]] && printf '%s\\n' '{\"data\":[{\"id\":\"openrouter/anthropic/claude-opus-4.8\"},{\"id\":\"deepseek/deepseek-v4-pro\"},{\"id\":\"zhipu/glm-4.7\"}]}' && exit 0\n"
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

def read_available(timeout: float = 0.2) -> bytes:
    captured = bytearray()
    end = time.time() + timeout
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.02)
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buffer.extend(data)
        captured.extend(data)
    return bytes(captured)


wait_for(b"Esc/Q cancel")
read_available(0.05)
# Default is Sonnet. Down selects Haiku and redraws in place without blanking
# the entire terminal; left/right are ignored; Enter launches.
os.write(fd, b"\x1b[B")
redraw = read_available()
for key in (b"\x1b[D", b"\x1b[C", b"\r"):
    os.write(fd, key)
    time.sleep(0.12)

end = time.time() + 8
status = None
while time.time() < end:
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        break
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            buffer.extend(os.read(fd, 65536))
        except OSError:
            pass
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
checks = {
    "Haiku launch": "ARGS: <--model> <haiku>" in text,
    "highlight": "❯" in text,
    "redraw keeps screen content": b"\x1b[2J" not in redraw,
    "redraw returns cursor home": redraw.startswith(b"\x1b[H"),
    "no escaped arrows": all(token not in text for token in ("^[[A", "^[[B", "^[[C", "^[[D")),
    "success": os.waitstatus_to_exitcode(status) == 0,
}
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if not all(checks.values()):
    print(text)
    sys.exit(1)
