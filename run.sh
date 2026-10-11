#!/usr/bin/env bash
set -euo pipefail

baud=${1:-9600}
emulator=$(command -v fab-agon-emulator) || { echo "fab-agon-emulator not found" >&2; exit 1; }
for tool in socat minicom xterm; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agon-uart1.XXXXXX")
cleanup() {
  if [[ -n ${terminal_pid:-} ]]; then kill "$terminal_pid" 2>/dev/null || true; fi
  if [[ -n ${emulator_pid:-} ]]; then kill "$emulator_pid" 2>/dev/null || true; fi
  if [[ -n ${socat_pid:-} ]]; then kill "$socat_pid" 2>/dev/null || true; wait "$socat_pid" 2>/dev/null || true; fi
  rm -rf -- "$tmpdir"
}
trap cleanup EXIT INT TERM

socat "PTY,link=$tmpdir/emulator,raw,echo=0" "PTY,link=$tmpdir/terminal,raw,echo=0" &
socat_pid=$!
for _ in {1..50}; do
  [[ -e $tmpdir/emulator && -e $tmpdir/terminal ]] && break
  sleep 0.1
done
[[ -e $tmpdir/emulator && -e $tmpdir/terminal ]] || { echo "Failed to create virtual serial pair" >&2; exit 1; }

"$emulator" --uart1-device "$tmpdir/emulator" --uart1-baud "$baud" &
emulator_pid=$!
sleep 0.5

xterm -T "Agon UART1 (XMODEM: Ctrl-A, S)" -e minicom --device "$tmpdir/terminal" --baudrate "$baud" &
terminal_pid=$!

wait "$emulator_pid"
wait "$terminal_pid" 2>/dev/null || true
