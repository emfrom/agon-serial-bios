#!/usr/bin/env python3
"""Smoke-test run.sh's emulator override and Minicom handoff without a GUI."""
from __future__ import annotations

import json
import os
import signal
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ST_STUB = r'''#!/usr/bin/env python3
import fcntl, pty, struct, subprocess, sys, termios
index = sys.argv.index("-e")
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 101, 0, 0))
try:
    result = subprocess.run(sys.argv[index + 1:], stdin=slave, stdout=slave,
                            stderr=subprocess.PIPE, check=False)
    sys.exit(result.returncode)
finally:
    import os
    os.close(master)
    os.close(slave)
'''

MINICOM_STUB = r'''#!/usr/bin/env python3
import json, os
from pathlib import Path
config = (Path(os.environ["HOME"]) / ".minirc.dfl").read_text().splitlines()
port = next(line.split(None, 2)[2] for line in config if line.startswith("pu port"))
updir = next(line.split(None, 2)[2] for line in config if line.startswith("pu updir"))
size = (Path(port).parent / "screen-size").read_text().strip()
Path(os.environ["RUN_TEST_RECORD"]).write_text(json.dumps({"updir": updir, "size": size}))
'''


def main() -> int:
    temp_dir = Path(subprocess.check_output(["mktemp", "-d"], text=True).strip())
    process: subprocess.Popen[bytes] | None = None
    try:
        stubs = temp_dir / "bin"
        stubs.mkdir()
        record = temp_dir / "minicom.json"
        emulator_record = temp_dir / "emulator.txt"
        emulator_args = temp_dir / "emulator-args.txt"
        version_args = temp_dir / "version-args.txt"
        firmware_dir = temp_dir / "firmware"
        firmware_dir.mkdir()
        (firmware_dir / "vdp_platform.so").touch()
        (firmware_dir / "mos_platform.bin").touch()
        (stubs / "fab-agon-emulator").write_text(
            '#!/bin/sh\nprintf default > "$RUN_TEST_EMULATOR"\nsleep 1\n'
        )
        emulator = temp_dir / "emulator-override"
        emulator.write_text(
            '#!/bin/sh\nif [ "$1" = "--version" ]; then\n'
            '  printf \'%s\\n\' "${RUN_TEST_VERSION:-fab-agon-emulator 1.2.5-empatch-abcdef}"\n'
            '  printf \'%s\\n\' "$@" > "$RUN_TEST_VERSION_ARGS"\n  exit 0\nfi\n'
            'printf override > "$RUN_TEST_EMULATOR"\n'
            'printf \'%s\\n\' "$@" > "$RUN_TEST_ARGS"\nsleep 1\n'
        )
        (stubs / "st").write_text(ST_STUB)
        (stubs / "minicom").write_text(MINICOM_STUB)
        for executable in [*stubs.iterdir(), emulator]:
            executable.chmod(0o755)

        env = {
            **os.environ,
            "PATH": f"{stubs}:{os.environ.get('PATH', '')}",
            "FAB_AGON_EMULATOR": str(emulator),
            "FAB_AGON_FIRMWARE_DIR": str(firmware_dir),
            "RUN_TEST_ARGS": str(emulator_args),
            "RUN_TEST_VERSION_ARGS": str(version_args),
            "RUN_TEST_EMULATOR": str(emulator_record),
            "RUN_TEST_RECORD": str(record),
            "RUN_TEST_BIN": str(ROOT / "bin"),
        }
        process = subprocess.Popen(
            [str(ROOT / "run.sh")], cwd=ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        stdout, stderr = process.communicate(timeout=10)
        if process.returncode:
            raise RuntimeError(f"run.sh failed: {stdout.decode()} {stderr.decode()}")
        result = json.loads(record.read_text())
        assert result["updir"] == str(ROOT / "bin"), result
        assert result["size"] == "31 101", result
        assert emulator_record.read_text() == "override"
        preflight_args = version_args.read_text().splitlines()
        assert "--version" in preflight_args and "--no-audio" in preflight_args
        passed_args = emulator_args.read_text().splitlines()
        assert passed_args[passed_args.index("--vdp") + 1] == str(firmware_dir / "vdp_platform.so")
        assert passed_args[passed_args.index("--mos") + 1] == str(firmware_dir / "mos_platform.bin")
        old_emulator = temp_dir / "old-emulator"
        old_emulator.write_text('#!/bin/sh\necho "fab-agon-emulator 1.2.5"\n')
        old_emulator.chmod(0o755)
        old_env = {**env, "FAB_AGON_EMULATOR": str(old_emulator)}
        rejected = subprocess.run(
            [str(ROOT / "run.sh")], cwd=ROOT, env=old_env,
            capture_output=True, text=True, timeout=5,
        )
        assert rejected.returncode != 0
        assert "patched Fab Agon Emulator" in rejected.stderr
        assert "https://github.com/emfrom/fab-agon-emulator/releases" in rejected.stderr

        timeout_emulator = temp_dir / "timeout-emulator"
        call_log = temp_dir / "preflight-calls.txt"
        timeout_emulator.write_text(
            '#!/bin/sh\nif [ "$1" = "--version" ]; then\n'
            '  echo called >> "$RUN_TEST_PREFLIGHT_CALLS"\n  exec sleep 30\nfi\n'
        )
        timeout_emulator.chmod(0o755)
        timeout_env = {
            **env,
            "FAB_AGON_EMULATOR": str(timeout_emulator),
            "RUN_TEST_PREFLIGHT_CALLS": str(call_log),
        }
        timed_out = subprocess.run(
            [str(ROOT / "run.sh")], cwd=ROOT, env=timeout_env,
            capture_output=True, text=True, timeout=6,
        )
        assert timed_out.returncode != 0
        assert call_log.read_text().splitlines() == ["called"], "preflight retried after timeout"
        assert "patched Fab Agon Emulator" in timed_out.stderr
        print("PASS: run.sh verifies emulator version, rejects stale builds, and does not retry timeouts")
    except subprocess.TimeoutExpired:
        if process is not None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    finally:
        subprocess.run(["rm", "-rf", "--", str(temp_dir)], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
