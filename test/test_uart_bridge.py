#!/usr/bin/env python3
"""Verify UART bridging and Minicom-compatible ANSI size replies."""
from __future__ import annotations

import os
import select
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUERY = b"\x1b[18t"


def read_available(fd: int, timeout: float = 3) -> bytes:
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        raise TimeoutError("timed out waiting for UART bridge data")
    return os.read(fd, 4096)


def read_expected(fd: int, expected: bytes, timeout: float = 3) -> None:
    data = bytearray()
    deadline = time.monotonic() + timeout
    while len(data) < len(expected):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {expected!r}; got {bytes(data)!r}")
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            raise TimeoutError(f"timed out waiting for {expected!r}; got {bytes(data)!r}")
        data.extend(os.read(fd, len(expected) - len(data)))
    assert bytes(data) == expected, f"expected {expected!r}, got {bytes(data)!r}"


def main() -> int:
    temp_dir = Path(subprocess.check_output(["mktemp", "-d"], text=True).strip())
    process: subprocess.Popen[str] | None = None
    ports: list[int] = []
    try:
        emulator_link = temp_dir / "emulator"
        terminal_link = temp_dir / "terminal"
        size_file = temp_dir / "screen-size"
        ready_file = temp_dir / "bios-ready"
        size_file.write_text("24 80\n")
        process = subprocess.Popen(
            [
                sys.executable,
                str(ROOT / "tools/ansi_uart_bridge.py"),
                "--emulator-link", str(emulator_link),
                "--terminal-link", str(terminal_link),
                "--size-file", str(size_file),
                "--ready-file", str(ready_file),
                "--discard-before-ready",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        ready_line = process.stdout.readline() if process.stdout else ""
        if ready_line.strip() != "UART bridge ready":
            raise RuntimeError(f"bridge failed to start: {ready_line!r}")

        emulator_fd = os.open(emulator_link, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        terminal_fd = os.open(terminal_link, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        ports.extend((emulator_fd, terminal_fd))

        os.write(emulator_fd, b"startup\r\nWaiting for XMODEM at 0x010000\r\nC")
        assert read_available(terminal_fd) == b"C", "bridge leaked BIOS startup text to the XMODEM sender"
        assert ready_file.read_text() == "ready\n"

        os.write(emulator_fd, QUERY)
        assert read_available(terminal_fd) == QUERY, "bridge did not forward ANSI query to Minicom"
        read_expected(emulator_fd, b"\x1b[8;24;80t")

        size_file.write_text("30 100\n")
        os.write(emulator_fd, QUERY)
        assert read_available(terminal_fd) == QUERY
        read_expected(emulator_fd, b"\x1b[8;30;100t")

        os.write(terminal_fd, b"w")
        assert read_available(emulator_fd) == b"w", "terminal input was not forwarded to emulator"
        print("PASS: bridge gates XMODEM on BIOS readiness, forwards bytes, and answers CSI 18 t")
    finally:
        for fd in ports:
            try:
                os.close(fd)
            except OSError:
                pass
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()
        subprocess.run(["rm", "-rf", "--", str(temp_dir)], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
