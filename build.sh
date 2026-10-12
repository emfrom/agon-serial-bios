#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
agondev_bin=$(cd -- "$root/../.." && pwd)/bin

cd "$root"
mkdir -p bin obj

"$agondev_bin/ez80-none-elf-as" -march=ez80+adl \
  -o obj/EZ80BIOS.o EZ80BIOS.s
"$agondev_bin/ez80-none-elf-ld" -T "$root/EZ80BIOS.ld" \
  --oformat binary -Map bin/EZ80BIOS.map \
  -o obj/EZ80BIOS.full.bin obj/EZ80BIOS.o
# Keep the low reset vector separate from the 8 KiB internal-SRAM BIOS image.
dd if=obj/EZ80BIOS.full.bin of=bin/bios_reset_stub.bin \
  bs=1 skip=0 count=8 status=none
[[ $(wc -c < bin/bios_reset_stub.bin) -eq 8 ]] || {
  echo "bios_reset_stub.bin must contain exactly 8 bytes" >&2
  exit 1
}
# The BIOS image occupies 0xE000..0xFFFF in the full address image.
dd if=obj/EZ80BIOS.full.bin of=bin/EZ80BIOS.bin \
  bs=1 skip=$((0xE000)) count=$((0x2000)) status=none
[[ $(wc -c < bin/EZ80BIOS.bin) -eq 8192 ]] || {
  echo "EZ80BIOS.bin must be exactly 8192 bytes" >&2
  exit 1
}

"$agondev_bin/ez80-none-elf-as" -march=ez80+adl \
  -o obj/helloserial.o helloserial.s
"$agondev_bin/ez80-none-elf-ld" -T "$root/helloserial.ld" \
  --oformat binary -Map bin/helloserial.map \
  -o obj/helloserial.full.bin obj/EZ80BIOS.o obj/helloserial.o
dd if=obj/helloserial.full.bin of=bin/helloserial.bin \
  bs=1 skip=$((0x10000)) status=none
[[ -s bin/helloserial.bin ]] || {
  echo "helloserial.bin was not generated" >&2
  exit 1
}

make

sdcard="$root/sdcard"
mkdir -p "$sdcard"
cp bin/EZ80BIOS.bin "$sdcard/EZ80BIOS.bin"
cp bin/bios_reset_stub.bin "$sdcard/bios_reset_stub.bin"
cp bin/biosloader.bin "$sdcard/biosloader.bin"
cp bin/helloserial.bin "$sdcard/helloserial.bin"
printf 'LOAD BIOSLOADER.BIN\nRUN\n' > "$sdcard/autoexec.txt"

echo "Copied BIOS, reset stub, biosloader, and helloserial; wrote autoexec.txt to $sdcard"
