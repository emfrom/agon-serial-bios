#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
agondev_bin=$(cd -- "$root/../.." && pwd)/bin

cd "$root"
mkdir -p bin obj

"$agondev_bin/ez80-none-elf-as" -march=ez80+adl \
  -o obj/EZ80BIOS.o EZ80BIOS.s
"$agondev_bin/ez80-none-elf-ld" -e 0xE000 -Ttext 0xE000 \
  --oformat binary -Map bin/EZ80BIOS.map \
  -o bin/EZ80BIOS.bin obj/EZ80BIOS.o

make

sdcard="$HOME/.agon-sdcard"
mkdir -p "$sdcard"
cp bin/EZ80BIOS.bin "$sdcard/EZ80BIOS.bin"
cp bin/ramtest.bin "$sdcard/ramtest.bin"
printf 'LOAD RAMTEST.BIN\nRUN\n' > "$sdcard/autoexec.txt"

echo "Copied BIOS and ramtest, and wrote autoexec.txt to $sdcard"
