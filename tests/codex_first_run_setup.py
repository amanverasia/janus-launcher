#!/usr/bin/env python3
"""Regression for Codex's interactive first-run URL and secret-key setup."""

import os
import pty
import re
import select
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="janus-codex-first-run-"))
BIN = TMP / "bin"
CONFIG = TMP / "config"
BIN.mkdir()
SECRET = b"first-run-secret-must-not-echo"

(BIN / "curl").write_text(
    "#!/usr/bin/env bash\n"
    "for arg in \"$@\"; do\n"
    "  [[ \"$arg\" == */v1/health ]] && exit 0\n"
    "  [[ \"$arg\" == */v1/models ]] && printf '%s\\n' '{\"data\":[{\"id\":\"provider/model-a\"}]}' && exit 0\n"
    "done\nexit 7\n"
)
(BIN / "curl").chmod(0o755)
(BIN / "codex").write_text(
    "#!/usr/bin/env bash\n"
    "printf 'CODEX_LAUNCHED=yes\\n'\n"
    "printf 'KEY_MATCH=%s\\n' \"$([[ \"$JANUS_LAUNCHER_CODEX_API_KEY\" == \"$EXPECTED_KEY\" ]] && printf yes || printf no)\"\n"
)
(BIN / "codex").chmod(0o755)

env = os.environ.copy()
env.update(
    PATH=f"{BIN}:/usr/bin:/bin",
    HOME=str(TMP / "home"),
    JANUS_LAUNCHER_CONFIG_DIR=str(CONFIG),
    EXPECTED_KEY=SECRET.decode(),
    TERM="xterm-256color",
)

pid, fd = pty.fork()
if pid == 0:
    os.execve(
        str(ROOT / "bin" / "codex-janus"),
        ["codex-janus", "--model", "provider/model-a"],
        env,
    )

raw = bytearray()


def wait_for(needle: bytes, timeout: float = 8) -> None:
    deadline = time.time() + timeout
    while needle not in raw and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            break
        raw.extend(chunk)
    if needle not in raw:
        raise RuntimeError(f"did not see {needle!r}: {bytes(raw)!r}")


wait_for(b"Janus base URL")
os.write(fd, b"http://127.0.0.1:20128/v1\n")
wait_for(b"Janus API key")
os.write(fd, SECRET + b"\n")

status = None
deadline = time.time() + 8
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(fd, 65536)
            if chunk:
                raw.extend(chunk)
        except OSError:
            pass
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        break
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)

output = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", bytes(raw))
router = CONFIG / "router.conf"
router_text = router.read_text() if router.exists() else ""
checks = {
    "API key prompted": b"Janus API key" in output,
    "secret not echoed": SECRET not in output,
    "normalized setup persisted": router_text
    == "JANUS_BASE_URL=http://127.0.0.1:20128\n"
    "JANUS_API_KEY=first-run-secret-must-not-echo\n",
    "Codex launched": b"CODEX_LAUNCHED=yes" in output,
    "Codex received key": b"KEY_MATCH=yes" in output,
    "success": os.waitstatus_to_exitcode(status) == 0,
}
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if not all(checks.values()):
    print(output.decode("utf-8", "replace"))
    print(router_text)
    raise SystemExit(1)
