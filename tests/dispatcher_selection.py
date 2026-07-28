#!/usr/bin/env python3
"""Pseudo-TTY coverage for dispatcher client selection and cancellation."""
import os
import pty
import re
import select
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="janus-dispatcher-test-"))
APP = TMP / "bin"
LIB = TMP / "lib"
APP.mkdir()
LIB.mkdir()
(APP / "janus-launcher").write_bytes((ROOT / "bin" / "janus-launcher").read_bytes()) if (ROOT / "bin" / "janus-launcher").exists() else None
(LIB / "janus_ui.sh").write_bytes((ROOT / "lib" / "janus_ui.sh").read_bytes())
if (APP / "janus-launcher").exists():
    (APP / "janus-launcher").chmod(0o755)
for client in ("claude", "codex"):
    command = APP / f"{client}-janus"
    command.write_text("#!/usr/bin/env bash\nprintf 'DELEGATED=%s ARGC=%d\\n' '" + client + "' \"$#\"\n")
    command.chmod(0o755)


def run_picker(keys: bytes) -> tuple[str, int]:
    launcher = APP / "janus-launcher"
    if not launcher.exists():
        return "dispatcher missing", 127
    env = os.environ.copy()
    env.update(PATH="/usr/bin:/bin", HOME=str(TMP / "home"), TERM="xterm-256color")
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(launcher), ["janus-launcher"], env)
    raw = bytearray()
    deadline = time.time() + 5
    while b"Choose a client" not in raw and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                raw.extend(os.read(fd, 65536))
            except OSError:
                break
    if b"Choose a client" in raw:
        os.write(fd, keys)
    status = None
    deadline = time.time() + 5
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
    return text, os.waitstatus_to_exitcode(status)


cases = (
    ("Claude", b"\r", "DELEGATED=claude ARGC=0", 0),
    ("Codex", b"\x1b[B\r", "DELEGATED=codex ARGC=0", 0),
    ("cancel", b"\x1b", "Usage: janus-launcher {claude|codex} [arguments...]", 130),
)
ok_all = True
for label, keys, expected, expected_status in cases:
    output, status = run_picker(keys)
    checks = {
        "delegation": expected in output,
        "status": status == expected_status,
        "terminal clean": "\x1b[A" not in output and "\x1b[B" not in output and "^[[" not in output,
    }
    for name, ok in checks.items():
        print(("PASS" if ok else "FAIL"), f"{label} {name}")
    if not all(checks.values()):
        print(output)
        ok_all = False
raise SystemExit(0 if ok_all else 1)
