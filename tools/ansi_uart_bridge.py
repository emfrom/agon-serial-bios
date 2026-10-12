#!/usr/bin/env python3
"""Bridge emulator/terminal PTYs and answer xterm's CSI 18 t size query."""
from __future__ import annotations

import argparse
import os
import pty
import selectors
import time
import tty
from pathlib import Path

SIZE_QUERY = b"\x1b[18t"
XMODEM_READY = b"Waiting for XMODEM at 0x010000\r\n"
DEFAULT_ROWS = 24
DEFAULT_COLUMNS = 80


def terminal_size(path: Path) -> bytes:
    try:
        rows_text, columns_text = path.read_text().split()
        rows, columns = int(rows_text), int(columns_text)
        if not (1 <= rows <= 255 and 1 <= columns <= 255):
            raise ValueError("terminal dimensions out of range")
    except (OSError, ValueError):
        rows, columns = DEFAULT_ROWS, DEFAULT_COLUMNS
    return f"\x1b[8;{rows};{columns}t".encode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator-link", required=True, type=Path)
    parser.add_argument("--terminal-link", required=True, type=Path)
    parser.add_argument("--size-file", required=True, type=Path)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--discard-before-ready", action="store_true")
    args = parser.parse_args()
    if args.discard_before_ready and args.ready_file is None:
        parser.error("--discard-before-ready requires --ready-file")

    emulator_master, emulator_slave = pty.openpty()
    terminal_master, terminal_slave = pty.openpty()
    for slave in (emulator_slave, terminal_slave):
        tty.setraw(slave)
        os.set_blocking(slave, False)
    os.set_blocking(emulator_master, False)
    os.set_blocking(terminal_master, False)
    os.symlink(os.ttyname(emulator_slave), args.emulator_link)
    os.symlink(os.ttyname(terminal_slave), args.terminal_link)

    print("UART bridge ready", flush=True)
    selector = selectors.DefaultSelector()
    queues = {emulator_master: bytearray(), terminal_master: bytearray()}
    selector.register(emulator_master, selectors.EVENT_READ, "emulator")
    selector.register(terminal_master, selectors.EVENT_READ, "terminal")
    scan_tail = b""
    ready_tail = b""
    ready = not args.discard_before_ready

    next_emulator_write = 0.0

    try:
        while True:
            now = time.monotonic()
            if queues[emulator_master] and now >= next_emulator_write:
                try:
                    written = os.write(emulator_master, queues[emulator_master][:1])
                    del queues[emulator_master][:written]
                    next_emulator_write = now + 0.0015
                except BlockingIOError:
                    next_emulator_write = now + 0.0015
                except OSError as exc:
                    if exc.errno not in (5, 9):
                        raise
            if queues[terminal_master]:
                try:
                    written = os.write(terminal_master, queues[terminal_master])
                    del queues[terminal_master][:written]
                except BlockingIOError:
                    pass
                except OSError as exc:
                    if exc.errno not in (5, 9):
                        raise

            for key, _events in selector.select(timeout=0.001):
                fd = key.fd
                try:
                    data = os.read(fd, 4096)
                except (BlockingIOError, OSError):
                    data = b""
                if not data:
                    continue
                if fd == emulator_master:
                    outgoing = data
                    if not ready:
                        scanned_ready = ready_tail + data
                        marker = scanned_ready.find(XMODEM_READY)
                        if marker < 0:
                            ready_tail = scanned_ready[-(len(XMODEM_READY) - 1):]
                            outgoing = b""
                        else:
                            ready = True
                            outgoing = scanned_ready[marker + len(XMODEM_READY):]
                            ready_tail = b""
                            args.ready_file.write_text("ready\n")
                    if outgoing:
                        queues[terminal_master].extend(outgoing)
                    scanned = scan_tail + data
                    cursor = 0
                    while True:
                        found = scanned.find(SIZE_QUERY, cursor)
                        if found < 0:
                            break
                        queues[emulator_master].extend(terminal_size(args.size_file))
                        cursor = found + len(SIZE_QUERY)
                    scan_tail = scanned[-(len(SIZE_QUERY) - 1):]
                else:
                    queues[emulator_master].extend(data)
    except KeyboardInterrupt:
        return 0
    finally:
        selector.close()
        for fd in (emulator_master, emulator_slave, terminal_master, terminal_slave):
            try:
                os.close(fd)
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
