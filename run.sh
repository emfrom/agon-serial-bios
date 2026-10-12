#!/usr/bin/env bash
set -euo pipefail

baud=115200
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
sdcard="$root/sdcard"

usage() {
  cat <<EOF
Usage: ${0##*/} [--xmodem FILE] [--help] [emulator arguments...]

Launch the Agon emulator with a temporary UART1 connection to Minicom.

Options:
  --xmodem FILE   Send FILE to the BIOS using XMODEM before opening Minicom
  -h, --help      Show this help and exit
  emulator args   Pass remaining arguments through to fab-agon-emulator

Examples:
  ${0##*/}
  ${0##*/} --xmodem bin/helloserial.bin
  ${0##*/} --debugger
EOF
}

xmodem_file=""
emulator_args=()
while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --xmodem)
      if [[ -n $xmodem_file || $# -lt 2 || $2 == --* ]]; then
        usage >&2
        exit 2
      fi
      xmodem_file=$2
      shift 2
      ;;
    --xmodem=*)
      if [[ -n $xmodem_file ]]; then
        echo "Specify --xmodem only once" >&2
        exit 2
      fi
      xmodem_file=${1#--xmodem=}
      [[ -n $xmodem_file ]] || { echo "--xmodem requires a file" >&2; exit 2; }
      shift
      ;;
    *)
      emulator_args+=("$1")
      shift
      ;;
  esac
done

mkdir -p "$sdcard"
emulator=$(command -v fab-agon-emulator) || { echo "fab-agon-emulator not found" >&2; exit 1; }
for tool in socat minicom; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done
if [[ -n $xmodem_file ]]; then
  [[ -r $xmodem_file ]] || { echo "Cannot read XMODEM file: $xmodem_file" >&2; exit 1; }
  command -v sx >/dev/null || { echo "sx (lrzsz) is required for --xmodem" >&2; exit 1; }
fi

terminal_bin=""
terminal_name=""
for candidate in st ghosty ghostty alacritty xterm; do
  if terminal_bin=$(command -v "$candidate" 2>/dev/null); then
    terminal_name=$candidate
    break
  fi
done
[[ -n $terminal_bin ]] || { echo "Install st, ghosty/ghostty, alacritty, or xterm" >&2; exit 1; }

debugger=0
for arg in "${emulator_args[@]}"; do
  [[ $arg == --debugger || $arg == -d ]] && debugger=1
done
if (( debugger )) && [[ -n $xmodem_file ]]; then
  echo "--xmodem cannot be combined with --debugger" >&2
  exit 2
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agon-serial-bios.XXXXXX")
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

emulator_args+=(--sdcard "$sdcard" --no-audio --uart1-device "$tmpdir/emulator" --uart1-baud "$baud")
title="agon-serial-bios UART1 (${baud} baud, 8N1)"
mkdir -p "$tmpdir/minicom-home"
cat > "$tmpdir/minicom-home/.minirc.dfl" <<EOF
pu port             $tmpdir/terminal
pu baudrate         $baud
pu bits             8
pu parity           N
pu stopbits         1
EOF
minicom_cmd=(env HOME="$tmpdir/minicom-home" minicom --device "$tmpdir/terminal" --baudrate "$baud" -8)
launch_terminal() {
  case "$terminal_name" in
    st)
      "$terminal_bin" -t "$title" -e "${minicom_cmd[@]}" & ;;
    ghosty|ghostty)
      "$terminal_bin" --title="$title" -e "${minicom_cmd[@]}" & ;;
    alacritty)
      "$terminal_bin" --title "$title" -e "${minicom_cmd[@]}" & ;;
    *)
      "$terminal_bin" -T "$title" -e "${minicom_cmd[@]}" & ;;
  esac
  terminal_pid=$!
}

echo "Using $terminal_name for Minicom."
if (( debugger )); then
  # The debugger reads commands from stdin, so keep it attached to this TTY.
  # Open the UART terminal first in this special interactive mode.
  launch_terminal
  SDL_VIDEODRIVER=dummy "$emulator" "${emulator_args[@]}"
  wait "$terminal_pid" 2>/dev/null || true
else
  # Normal mode starts the emulator before any UART client.
  SDL_VIDEODRIVER=dummy "$emulator" "${emulator_args[@]}" &
  emulator_pid=$!
  sleep 0.5
  if [[ -n $xmodem_file ]]; then
    echo "Sending $xmodem_file with XMODEM..."
    sx -X -b -- "$xmodem_file" < "$tmpdir/terminal" > "$tmpdir/terminal"
    echo "XMODEM upload finished; launching Minicom."
  fi
  launch_terminal
  wait "$emulator_pid"
  wait "$terminal_pid" 2>/dev/null || true
fi
