#!/usr/bin/env python3
"""Pseudo-TTY regression for secret-safe first-time API-key input."""
import os
import pty
import select
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="janus-api-key-setup-"))
SECRET = b"typed-secret-must-not-echo"

env = os.environ.copy()
env.update(HOME=str(TMP / "home"), JANUS_LAUNCHER_CONFIG_DIR=str(TMP / "config"), TERM="xterm-256color")
pid, fd = pty.fork()
if pid == 0:
    os.execve(
        "/usr/bin/bash",
        [
            "bash",
            "-c",
            'source "$1/lib/janus_api.sh"; source "$1/lib/janus_config.sh"; source "$1/lib/janus_ui.sh"; janus_config_init_paths; janus_ui_init; janus_config_run_first_setup',
            "_",
            str(ROOT),
        ],
        env,
    )


def relevant(attributes: list) -> tuple:
    return (*attributes[:4], attributes[6][termios.VMIN], attributes[6][termios.VTIME])


before = relevant(termios.tcgetattr(fd))
raw = bytearray()
deadline = time.time() + 5
while b"Janus base URL" not in raw and time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        raw.extend(os.read(fd, 65536))
os.write(fd, b"https://router.example\n")
deadline = time.time() + 5
while b"Janus API key" not in raw and time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        raw.extend(os.read(fd, 65536))
os.write(fd, SECRET + b"\n")

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
after = relevant(termios.tcgetattr(fd))
while True:
    ready, _, _ = select.select([fd], [], [], 0.05)
    if not ready:
        break
    try:
        raw.extend(os.read(fd, 65536))
    except OSError:
        break

router = TMP / "config" / "router.conf"
router_text = router.read_text() if router.exists() else ""
checks = {
    "secret absent from terminal output": SECRET not in bytes(raw),
    "secret persisted": "JANUS_API_KEY=typed-secret-must-not-echo\n" in router_text,
    "prompt newline emitted": bytes(raw).endswith(b"Janus API key: \r\n") or bytes(raw).endswith(b"Janus API key: \n"),
    "terminal restored": after == before,
    "success": os.waitstatus_to_exitcode(status) == 0,
}
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if not all(checks.values()):
    print(bytes(raw))
    raise SystemExit(1)
