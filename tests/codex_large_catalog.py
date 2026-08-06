#!/usr/bin/env python3
"""PTY regression for searchable selection from a very large Janus catalog."""

import json
import os
import pty
import re
import select
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="janus-codex-large-catalog-"))
BIN = TMP / "bin"
CONFIG = TMP / "config"
CATALOG_FILE = TMP / "models.json"
BIN.mkdir()
CONFIG.mkdir()

models = [f"provider/model-{index:03d}" for index in range(1, 831)]
models.append("zhipu/glm-5")
CATALOG_FILE.write_text(json.dumps({"data": [{"id": model} for model in models]}))

(BIN / "curl").write_text(
    "#!/usr/bin/env bash\n"
    "for arg in \"$@\"; do\n"
    "  [[ \"$arg\" == */v1/health ]] && exit 0\n"
    "  [[ \"$arg\" == */v1/models ]] && cat \"$JANUS_TEST_CATALOG\" && exit 0\n"
    "done\nexit 7\n"
)
(BIN / "curl").chmod(0o755)
(BIN / "codex").write_text(
    "#!/usr/bin/env bash\n"
    "i=0\n"
    "for arg in \"$@\"; do printf 'ARG[%d]=%s\\n' \"$i\" \"$arg\"; ((i += 1)); done\n"
)
(BIN / "codex").chmod(0o755)

env = os.environ.copy()
env.update(
    PATH=f"{BIN}:/usr/bin:/bin",
    HOME=str(TMP / "home"),
    JANUS_LAUNCHER_CONFIG_DIR=str(CONFIG),
    JANUS_LAUNCHER_BASE_URL="https://router.example",
    JANUS_LAUNCHER_API_KEY="test-key",
    JANUS_TEST_CATALOG=str(CATALOG_FILE),
    TERM="xterm-256color",
)

pid, fd = pty.fork()
if pid == 0:
    os.execve(str(ROOT / "bin" / "codex-janus"), ["codex-janus"], env)

raw = bytearray()


def wait_for(needle: bytes, timeout: float = 8) -> None:
    deadline = time.time() + timeout
    while needle not in raw and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            break
        raw.extend(data)
    if needle not in raw:
        raise RuntimeError(f"did not see {needle!r}: {bytes(raw)[-4000:]!r}")


wait_for(b"831 models are available")
os.write(fd, b"ZHIPU/GLM-5\n")
wait_for(b"1 matching models")
os.write(fd, b"1\r")

status = None
deadline = time.time() + 8
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            data = os.read(fd, 65536)
            if data:
                raw.extend(data)
        except OSError:
            pass
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        break
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)

text = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", bytes(raw)).decode(
    "utf-8", "replace"
)
state = CONFIG / "codex.conf"
state_text = state.read_text() if state.exists() else ""
checks = {
    "search prompt shown": "831 models are available" in text,
    "catalog not dumped": "provider/model-001" not in text
    and "provider/model-830" not in text,
    "filtered model shown": "zhipu/glm-5" in text,
    "filtered model persisted": state_text == "MODEL=zhipu/glm-5\n",
    "empty-argument launch succeeds": "ARG[11]=zhipu/glm-5" in text,
    "success": os.waitstatus_to_exitcode(status) == 0,
}
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL"), name)
if not all(checks.values()):
    print(text)
    print(state_text)
    raise SystemExit(1)
