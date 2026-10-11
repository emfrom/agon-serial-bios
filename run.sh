#!/usr/bin/env bash
set -euo pipefail

baud=115200
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

emulator_args=("$@" --no-audio --uart1-device "$tmpdir/emulator" --uart1-baud "$baud")
debugger=0
for arg in "$@"; do
  [[ $arg == --debugger || $arg == -d ]] && debugger=1
done

mkdir -p "$tmpdir/minicom-home"
cat > "$tmpdir/minicom-home/.minirc.dfl" <<EOF
pu port             $tmpdir/terminal
pu baudrate         $baud
pu bits             8
pu parity           N
pu stopbits         1
EOF
launch_terminal() {
  xterm -T "Agon UART1 (${baud} baud, 8N1)" -e env HOME="$tmpdir/minicom-home" \
    minicom --device "$tmpdir/terminal" --baudrate "$baud" -8 &
  terminal_pid=$!
}

if (( debugger )); then
  # The debugger reads commands from stdin, so keep it attached to this TTY.
  # Open the UART terminal first in this special interactive mode.
  launch_terminal
  "$emulator" "${emulator_args[@]}"
  wait "$terminal_pid" 2>/dev/null || true
else
  # Normal mode starts the emulator before its UART terminal client.
  "$emulator" "${emulator_args[@]}" &
  emulator_pid=$!
  sleep 0.5
  launch_terminal
  wait "$emulator_pid"
  wait "$terminal_pid" 2>/dev/null || true
fi
