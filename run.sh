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
if [[ -n ${FAB_AGON_EMULATOR:-} ]]; then
  emulator=$FAB_AGON_EMULATOR
  [[ -x $emulator ]] || { echo "FAB_AGON_EMULATOR is not executable: $emulator" >&2; exit 1; }
else
  emulator=$(command -v fab-agon-emulator) || { echo "fab-agon-emulator not found" >&2; exit 1; }
fi
command -v timeout >/dev/null || { echo "timeout is required for the emulator pre-flight check" >&2; exit 1; }
if ! version_output=$(SDL_VIDEODRIVER=dummy timeout -k 1s 3s "$emulator" --version --no-audio 2>&1) ||
   ! grep -Eq 'empatch-[[:xdigit:]]{6}' <<<"$version_output"; then
  echo "Error: this launcher requires our patched Fab Agon Emulator (version must include empatch-<6 hex digits>)." >&2
  [[ -n $version_output ]] && printf 'Emulator response: %s\n' "$version_output" >&2
  echo "Download the patched emulator: https://github.com/emfrom/fab-agon-emulator/releases" >&2
  exit 1
fi

firmware=platform
has_vdp=0
has_mos=0
for ((i=0; i<${#emulator_args[@]}; i++)); do
  case ${emulator_args[i]} in
    --vdp) has_vdp=1; i=$((i + 1)) ;;
    --vdp=*) has_vdp=1 ;;
    --mos) has_mos=1; i=$((i + 1)) ;;
    --mos=*) has_mos=1 ;;
    --firmware)
      if ((i + 1 < ${#emulator_args[@]})); then
        firmware=${emulator_args[i + 1]}
        i=$((i + 1))
      fi
      ;;
    --firmware=*) firmware=${emulator_args[i]#*=} ;;
  esac
done
firmware_dir=${FAB_AGON_FIRMWARE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fab-agon-emulator}
if ((!has_vdp)); then
  vdp_firmware="$firmware_dir/vdp_${firmware}.so"
  [[ -r $vdp_firmware ]] || vdp_firmware="$firmware_dir/vdp_console8.so"
  [[ -r $vdp_firmware ]] || { echo "VDP firmware not found in $firmware_dir (set FAB_AGON_FIRMWARE_DIR or pass --vdp)" >&2; exit 1; }
  emulator_args+=(--vdp "$vdp_firmware")
fi
if ((!has_mos)); then
  mos_firmware="$firmware_dir/mos_${firmware}.bin"
  [[ -r $mos_firmware ]] || mos_firmware="$firmware_dir/mos_console8.bin"
  [[ -r $mos_firmware ]] || { echo "MOS firmware not found in $firmware_dir (set FAB_AGON_FIRMWARE_DIR or pass --mos)" >&2; exit 1; }
  emulator_args+=(--mos "$mos_firmware")
fi
for tool in python3 minicom; do
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
  if [[ -n ${bridge_pid:-} ]]; then kill "$bridge_pid" 2>/dev/null || true; wait "$bridge_pid" 2>/dev/null || true; fi
  rm -rf -- "$tmpdir"
}
trap cleanup EXIT INT TERM

printf '24 80\n' > "$tmpdir/screen-size"
bridge_args=(
  --emulator-link "$tmpdir/emulator"
  --terminal-link "$tmpdir/terminal"
  --size-file "$tmpdir/screen-size"
)
if [[ -n $xmodem_file ]]; then
  bridge_args+=(--ready-file "$tmpdir/bios-ready" --discard-before-ready)
fi
python3 "$root/tools/ansi_uart_bridge.py" "${bridge_args[@]}" &
bridge_pid=$!
for _ in {1..50}; do
  [[ -e $tmpdir/emulator && -e $tmpdir/terminal ]] && break
  sleep 0.1
done
[[ -e $tmpdir/emulator && -e $tmpdir/terminal ]] || { echo "Failed to create UART bridge" >&2; exit 1; }

emulator_args+=(--sdcard "$sdcard" --no-audio --uart1-device "$tmpdir/emulator" --uart1-baud "$baud")
title="agon-serial-bios UART1 (${baud} baud, 8N1)"
mkdir -p "$tmpdir/minicom-home"
cat > "$tmpdir/minicom-home/.minirc.dfl" <<EOF
pu port             $tmpdir/terminal
pu baudrate         $baud
pu bits             8
pu parity           N
pu stopbits         1
pu updir            $root/bin
EOF
minicom_cmd=(bash -c 'stty size > "$1"; shift; exec "$@"' minicom-wrapper \
  "$tmpdir/screen-size" env HOME="$tmpdir/minicom-home" minicom \
  --device "$tmpdir/terminal" --baudrate "$baud" -8)
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
    for _ in {1..300}; do
      [[ -e $tmpdir/bios-ready ]] && break
      if ! kill -0 "$emulator_pid" 2>/dev/null; then
        echo "Emulator exited before BIOS requested XMODEM" >&2
        exit 1
      fi
      sleep 0.1
    done
    [[ -e $tmpdir/bios-ready ]] || { echo "Timed out waiting for BIOS XMODEM prompt" >&2; exit 1; }
    echo "Sending $xmodem_file with XMODEM..."
    sx -X -b -- "$xmodem_file" < "$tmpdir/terminal" > "$tmpdir/terminal"
    echo "XMODEM upload finished; launching Minicom."
  fi
  launch_terminal
  wait "$emulator_pid"
  wait "$terminal_pid" 2>/dev/null || true
fi
