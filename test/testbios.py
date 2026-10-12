#!/usr/bin/env python3
"""Build and run the RST 10h BIOS API test program using lrzsz's sx."""
from __future__ import annotations

import argparse
import os
import pty
import shutil
import subprocess
import sys
import tempfile
import time
import tty
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class Harness:
    def __init__(self, emulator: str, firmware: list[str], timeout: float):
        self.timeout = timeout
        self.output = bytearray()
        self.chunks: list[tuple[int, bytes, float]] = []
        self.to_emulator = bytearray()
        self.to_sx = bytearray()
        self.sx_process: subprocess.Popen[bytes] | None = None
        self.sx_stderr = None
        self.next_tx_time = 0.0
        self.tx_interval = 0.0015
        self.emulator_master, emulator_slave = pty.openpty()
        self.sx_master, self.sx_slave = pty.openpty()
        tty.setraw(emulator_slave)
        tty.setraw(self.sx_slave)
        self.emulator_path = os.ttyname(emulator_slave)
        os.set_blocking(self.emulator_master, False)
        os.set_blocking(self.sx_master, False)
        command = [emulator, "--sdcard", str(ROOT / "sdcard"), "--no-audio",
                   "--uart1-device", self.emulator_path, "--uart1-baud", "115200"]
        command.extend(firmware)
        self.emulator = subprocess.Popen(
            command,
            cwd=ROOT,
            env={**os.environ, "SDL_VIDEODRIVER": "dummy"},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        os.close(emulator_slave)

    def pump(self, wait: float = 0.01) -> None:
        import select

        readers = [self.emulator_master]
        if self.sx_process is not None:
            readers.append(self.sx_master)
        ready, _, _ = select.select(readers, [], [], wait)
        for fd in ready:
            try:
                data = os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError:
                continue
            if not data:
                continue
            if fd == self.emulator_master:
                self.chunks.append((len(self.output), data, time.monotonic()))
                self.output.extend(data)
                if self.sx_process is not None:
                    self.to_sx.extend(data)
            elif self.sx_process is not None:
                self.to_emulator.extend(data)

        if self.sx_process is not None and self.to_sx:
            try:
                written = os.write(self.sx_master, self.to_sx)
                del self.to_sx[:written]
            except (BlockingIOError, OSError):
                pass

        now = time.monotonic()
        if self.to_emulator and now >= self.next_tx_time:
            try:
                os.write(self.emulator_master, self.to_emulator[:1])
                del self.to_emulator[:1]
                self.next_tx_time = now + self.tx_interval
            except (BlockingIOError, OSError):
                pass

        if self.emulator.poll() is not None:
            raise RuntimeError("emulator exited unexpectedly: " + self.emulator_error())

    def wait_for(self, marker: bytes, timeout: float | None = None) -> float:
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while marker not in self.output:
            if b"FAIL:" in self.output:
                for _ in range(5):
                    self.pump(0.01)
                raise AssertionError("test BIOS reported failure: " + repr(bytes(self.output[-300:])))
            if time.monotonic() >= deadline:
                raise TimeoutError(f"timed out waiting for {marker!r}; UART tail={bytes(self.output[-300:])!r}")
            self.pump(0.01)
        offset = self.output.find(marker)
        for start, data, timestamp in self.chunks:
            if start <= offset < start + len(data):
                return timestamp
        return time.monotonic()

    def start_sx(self, filename: Path) -> None:
        if self.sx_process is not None:
            raise RuntimeError("sx transfer already active")
        tty.setraw(self.sx_slave)
        self.sx_stderr = tempfile.TemporaryFile()
        self.sx_process = subprocess.Popen(
            ["sx", "-X", "-b", "--", str(filename)],
            stdin=self.sx_slave,
            stdout=self.sx_slave,
            stderr=self.sx_stderr,
            cwd=ROOT,
        )
        self.to_sx.clear()
        self.to_emulator.clear()
        self.next_tx_time = time.monotonic()

    def finish_sx(self, expect_failure: bool = False) -> None:
        assert self.sx_process is not None
        deadline = time.monotonic() + self.timeout
        while self.sx_process.poll() is None or self.to_emulator:
            if time.monotonic() >= deadline:
                self.sx_process.kill()
                raise TimeoutError("sx transfer timed out")
            self.pump(0.005)
        status = self.sx_process.wait()
        self.pump(0.1)
        if (status != 0) != expect_failure:
            self.sx_stderr.seek(0)
            detail = self.sx_stderr.read().decode(errors="replace")
            expected = "failure" if expect_failure else "success"
            raise RuntimeError(f"sx exited with {status}, expected {expected}: {detail}")
        self.sx_stderr.close()
        self.sx_stderr = None
        self.sx_process = None
        self.to_sx.clear()
        self.to_emulator.clear()

    def send(self, data: bytes) -> None:
        for byte in data:
            deadline = time.monotonic() + 2
            while True:
                try:
                    os.write(self.emulator_master, bytes([byte]))
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("could not send test input")
                    self.pump(0.005)
            time.sleep(self.tx_interval)

    def emulator_error(self) -> str:
        if self.emulator.stderr is None:
            return ""
        try:
            return self.emulator.stderr.read().decode(errors="replace")[-1000:]
        except OSError:
            return ""

    def close(self) -> None:
        if self.sx_process is not None and self.sx_process.poll() is None:
            self.sx_process.terminate()
            try:
                self.sx_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.sx_process.kill()
                self.sx_process.wait()
        if self.sx_stderr is not None:
            self.sx_stderr.close()
        self.emulator.terminate()
        try:
            self.emulator.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.emulator.kill()
            self.emulator.wait()
        for fd in (self.emulator_master, self.sx_master, self.sx_slave):
            try:
                os.close(fd)
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emulator", default=shutil.which("fab-agon-emulator"),
                        help="emulator executable (default: fab-agon-emulator on PATH)")
    parser.add_argument("--vdp", help="optional VDP firmware library path")
    parser.add_argument("--mos", help="optional MOS firmware path")
    parser.add_argument("--timeout", type=float, default=45.0,
                        help="per-stage timeout in seconds (default: 45)")
    args = parser.parse_args()
    if not args.emulator:
        parser.error("fab-agon-emulator not found; pass --emulator PATH")
    if shutil.which("sx") is None:
        parser.error("sx (from lrzsz) is required")

    build_env = {**os.environ, "PATH": f"{ROOT.parent.parent / 'bin'}:{os.environ.get('PATH', '')}"}
    build = subprocess.run([str(ROOT / "build.sh")], cwd=ROOT, env=build_env, check=False)
    if build.returncode:
        return build.returncode

    firmware: list[str] = []
    default_vdp = Path.home() / ".local/share/fab-agon-emulator/vdp_platform.so"
    default_mos = Path.home() / ".local/share/fab-agon-emulator/mos_platform.bin"
    vdp = args.vdp or (str(default_vdp) if default_vdp.exists() else None)
    mos = args.mos or (str(default_mos) if default_mos.exists() else None)
    if vdp:
        firmware.extend(["--vdp", vdp])
    if mos:
        firmware.extend(["--mos", mos])

    payload = bytes([ord("X")]) * 256
    with tempfile.TemporaryDirectory(prefix="testbios-") as temp:
        xmodem_payload = Path(temp) / "xmodem-payload.bin"
        xmodem_payload.write_bytes(payload)
        harness = Harness(args.emulator, firmware, args.timeout)
        try:
            harness.wait_for(b"Waiting for XMODEM at 0x010000")
            harness.start_sx(ROOT / "bin/testbios.bin")
            harness.finish_sx()
            harness.wait_for(b"Load complete")
            harness.send(b"R")
            harness.wait_for(b"TESTBIOS:START")

            harness.wait_for(b"TESTBIOS:PUTCHAR:A\x00Z\r\n")
            harness.wait_for(b"TESTBIOS:PUTS:onetwo\r\n")
            wait_start = harness.wait_for(b"TESTBIOS:WAIT_BEGIN")
            wait_end = harness.wait_for(b"TESTBIOS:WAIT_END")
            assert wait_end - wait_start >= 0.07, f"WAIT ran too quickly: {wait_end - wait_start:.3f}s"
            for marker in (b"PASS:CALL_HL", b"PASS:CALL_HL_SECOND", b"PASS:BAD_OPERATION", b"PASS:EMPTY_AND_ZERO_NREAD", b"PASS:VECTOR_EXTENSIONS"):
                harness.wait_for(marker)

            harness.wait_for(b"TESTBIOS:GETCHAR_READY")
            harness.send(b"G")
            harness.wait_for(b"PASS:GETCHAR")
            harness.wait_for(b"TESTBIOS:GETCHAR2_READY")
            harness.send(b"H")
            harness.wait_for(b"PASS:GETCHAR_SECOND")

            harness.wait_for(b"TESTBIOS:PEEK_READY")
            harness.send(b"P")
            harness.wait_for(b"PASS:PEEK_AND_RX_GET")

            harness.wait_for(b"TESTBIOS:RXGET_READY")
            harness.send(b"RS")
            harness.wait_for(b"PASS:RX_GET_MULTI")

            harness.wait_for(b"TESTBIOS:NREAD1_READY")
            harness.send(b"1")
            harness.wait_for(b"PASS:NREAD1")
            harness.wait_for(b"TESTBIOS:NREAD3_READY")
            harness.send(b"ABC")
            harness.wait_for(b"PASS:NREAD3")
            harness.wait_for(b"TESTBIOS:NREAD128_READY")
            harness.send(b"N" * 128)
            harness.wait_for(b"PASS:NREAD128")

            harness.wait_for(b"TESTBIOS:XMODEM_READY")
            harness.start_sx(xmodem_payload)
            harness.finish_sx()
            harness.wait_for(b"PASS:XMODEM_RX")

            harness.wait_for(b"TESTBIOS:XMODEM_LIMIT_READY")
            harness.start_sx(xmodem_payload)
            harness.finish_sx(expect_failure=True)
            harness.wait_for(b"PASS:XMODEM_MAX_SIZE")

            harness.wait_for(b"TESTBIOS:TX_QUEUE_BEGIN")
            harness.wait_for(b"PASS:TX_PUT_FULL\r\n")
            tx_start_marker = b"TESTBIOS:TX_QUEUE_BEGIN\r\n"
            tx_start = harness.output.index(tx_start_marker) + len(tx_start_marker)
            tx_end = harness.output.index(b"PASS:TX_PUT_FULL\r\n", tx_start)
            tx_bytes = harness.output[tx_start:tx_end]
            assert tx_bytes == b"Q" * 255, f"TX_PUT emitted {len(tx_bytes)} bytes; expected 255 Q bytes"
            harness.wait_for(b"TESTBIOS:ALL_PASS")
            assert b"FAIL:" not in harness.output
            time.sleep(0.2)
            assert b"FAIL:HALT_RETURNED" not in harness.output
            print("PASS: all BIOS RST 10h operations; XMODEM transfers used sx")
            print("UART transcript:")
            print("".join(
                chr(byte) if byte in (10, 13) or 0x20 <= byte < 0x7F else f"\\x{byte:02x}"
                for byte in harness.output
            ))
            return 0
        except Exception:
            print("UART transcript tail:", repr(bytes(harness.output[-1000:])), file=sys.stderr)
            raise
        finally:
            harness.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
