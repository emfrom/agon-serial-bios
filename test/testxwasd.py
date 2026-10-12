#!/usr/bin/env python3
"""Exercise xwasd over the real BIOS/UART emulator path with an ANSI terminal peer."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from testbios import Harness  # noqa: E402

WAITING = b"Waiting for XMODEM at 0x010000"
LOAD_COMPLETE = b"Load complete"
SIZE_QUERY = b"\x1b[18t"


def wait_after(harness: Harness, marker: bytes, start: int, timeout: float = 15) -> bytes:
    deadline = time.monotonic() + timeout
    while marker not in harness.output[start:]:
        if time.monotonic() >= deadline:
            raise TimeoutError(
                f"timed out waiting for {marker!r}; UART tail={bytes(harness.output[-300:])!r}"
            )
        harness.pump(0.01)
    return bytes(harness.output[start:])


def assert_no_output(harness: Harness, duration: float = 0.15) -> None:
    start = len(harness.output)
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        harness.pump(0.01)
    extra = bytes(harness.output[start:])
    assert not extra, f"unexpected UART output: {extra!r}"


def start_game(harness: Harness, binary: Path) -> None:
    start = len(harness.output)
    harness.start_sx(binary)
    harness.finish_sx()
    wait_after(harness, LOAD_COMPLETE, start)
    harness.send(b"R")

    start = len(harness.output)
    wait_after(harness, SIZE_QUERY, start)
    start = len(harness.output)
    output = wait_after(harness, b"\x1b[12;40HX", start)
    assert b"\x1b[2J\x1b[12;40HX" in output, "did not clear and draw X at 24x80 center"


def move(harness: Harness, key: bytes, old: tuple[int, int], new: tuple[int, int]) -> None:
    start = len(harness.output)
    harness.send(key)
    old_cursor = f"\x1b[{old[0]};{old[1]}H ".encode()
    new_cursor = f"\x1b[{new[0]};{new[1]}HX".encode()
    output = wait_after(harness, new_cursor, start)
    assert old_cursor + new_cursor in output, f"move {key!r} did not erase old X: {output[-100:]!r}"


def build() -> None:
    build_env = {
        **os.environ,
        "PATH": f"{ROOT.parent.parent / 'bin'}:{os.environ.get('PATH', '')}",
    }
    result = subprocess.run([str(ROOT / "build.sh")], cwd=ROOT, env=build_env, check=False)
    if result.returncode:
        raise SystemExit(result.returncode)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", default=shutil.which("fab-agon-emulator"))
    parser.add_argument("--vdp", help="optional VDP firmware library path")
    parser.add_argument("--mos", help="optional MOS firmware path")
    parser.add_argument("--timeout", type=float, default=45)
    args = parser.parse_args()
    if not args.emulator:
        parser.error("fab-agon-emulator not found; pass --emulator PATH")
    if shutil.which("sx") is None:
        parser.error("sx (from lrzsz) is required")

    build()
    firmware: list[str] = []
    default_vdp = Path.home() / ".local/share/fab-agon-emulator/vdp_platform.so"
    default_mos = Path.home() / ".local/share/fab-agon-emulator/mos_platform.bin"
    vdp = args.vdp or (str(default_vdp) if default_vdp.exists() else None)
    mos = args.mos or (str(default_mos) if default_mos.exists() else None)
    if vdp:
        firmware.extend(["--vdp", vdp])
    if mos:
        firmware.extend(["--mos", mos])

    harness = Harness(args.emulator, firmware, args.timeout, ansi_bridge=True)
    binary = ROOT / "bin/xwasd.bin"
    try:
        harness.wait_for(WAITING)
        start_game(harness, binary)

        move(harness, b"w", (12, 40), (11, 40))
        move(harness, b"a", (11, 40), (11, 39))
        move(harness, b"s", (11, 39), (12, 39))
        move(harness, b"d", (12, 39), (12, 40))

        harness.send(b"q")
        assert_no_output(harness)

        # Verify the top, left, bottom, and right edges stop movement.
        harness.send(b"w" * 11)
        wait_after(harness, b"\x1b[1;40HX", len(harness.output) - 512)
        harness.send(b"w")
        assert_no_output(harness)
        harness.send(b"a" * 39)
        wait_after(harness, b"\x1b[1;1HX", len(harness.output) - 2048)
        harness.send(b"a")
        assert_no_output(harness)
        harness.send(b"s" * 23)
        wait_after(harness, b"\x1b[24;1HX", len(harness.output) - 2048)
        harness.send(b"s")
        assert_no_output(harness)
        harness.send(b"d" * 79)
        wait_after(harness, b"\x1b[24;80HX", len(harness.output) - 4096)
        harness.send(b"d")
        assert_no_output(harness)

        # Every designated non-movement key must return to the BIOS soft start.
        for index, key in enumerate((b"\x03", b"\x04", b" ", b"\r")):
            start = len(harness.output)
            harness.send(key)
            wait_after(harness, WAITING, start)
            if index != 3:
                start_game(harness, binary)

        print("PASS: xwasd terminal query, center, WASD movement, edge stops, ignored key, and restart keys")
    finally:
        harness.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
