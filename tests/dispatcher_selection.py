#!/usr/bin/env python3
"""Pseudo-TTY coverage for dispatcher client selection and cancellation."""
import os
import pty
import re
import select
import tempfile
import termios
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


def relevant_termios(attributes: list) -> tuple:
    return (*attributes[:4], attributes[6][termios.VMIN], attributes[6][termios.VTIME])


def run_picker(keys: bytes) -> tuple[str, bytes, int, bool]:
    launcher = APP / "janus-launcher"
    if not launcher.exists():
        return "dispatcher missing", b"", 127, False
    env = os.environ.copy()
    env.update(PATH="/usr/bin:/bin", HOME=str(TMP / "home"), TERM="xterm-256color")
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(str(launcher), ["janus-launcher"], env)
    before = relevant_termios(termios.tcgetattr(fd))
    raw = bytearray()
    deadline = time.time() + 5
    while b"Choose a client" not in raw and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 65536)
                if not data:
                    break
                raw.extend(data)
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
                data = os.read(fd, 65536)
                if data:
                    raw.extend(data)
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
            data = os.read(fd, 65536)
            if not data:
                break
            raw.extend(data)
        except OSError:
            break
    after = relevant_termios(termios.tcgetattr(fd))
    raw_bytes = bytes(raw)
    text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", raw_bytes).decode("utf-8", "replace")
    return text, raw_bytes, os.waitstatus_to_exitcode(status), after == before


cases = (
    ("Claude", b"\x1b[B\x1b[A\r", "DELEGATED=claude ARGC=0", 0),
    ("Codex", b"\x1b[B\r", "DELEGATED=codex ARGC=0", 0),
    ("cancel", b"\x1b[B\x1b", "Usage: janus-launcher {claude|codex} [arguments...]", 130),
)
ok_all = True
for label, keys, expected, expected_status in cases:
    output, raw_output, status, terminal_restored = run_picker(keys)
    arrow_input = b"\x1b[B" if b"\x1b[B" in keys else None
    checks = {
        "delegation": expected in output,
        "status": status == expected_status,
        "terminal restored": terminal_restored,
        "raw arrow input not leaked": arrow_input is None or arrow_input not in raw_output,
    }
    for name, ok in checks.items():
        print(("PASS" if ok else "FAIL"), f"{label} {name}")
    if not all(checks.values()):
        print(output)
        ok_all = False
raise SystemExit(0 if ok_all else 1)
