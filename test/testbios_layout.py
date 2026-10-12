#!/usr/bin/env python3
"""Lock down the BIOS compile-time internal-SRAM layout."""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL_BIN = ROOT.parent.parent / "bin"
EXPECTED = {
    "bios_ivt_table": 0xE000,
    "bios_entry": 0xE000,
    "bios_hard_start": 0xE000,
    "bios_rs_head": 0xE068,
    "bios_stack": 0xE100,
    "bios_stack_top": 0xE200,
    "bios_rs_ring": 0xE200,
    "bios_ts_ring": 0xE300,
    "bios_rst_vector_defaults": 0xE400,
    "bios_ivt_defaults": 0xE440,
    "bios_soft_start": 0xE4A8,
}


def main() -> int:
    env = {**os.environ, "PATH": f"{TOOL_BIN}:{os.environ.get('PATH', '')}"}
    result = subprocess.run([str(ROOT / "build.sh")], cwd=ROOT, env=env, check=False)
    if result.returncode:
        return result.returncode

    nm = subprocess.run(
        [str(TOOL_BIN / "ez80-none-elf-nm"), "-n", "obj/EZ80BIOS.o"],
        cwd=ROOT, env=env, check=True, capture_output=True, text=True,
    )
    symbols: dict[str, int] = {}
    for line in nm.stdout.splitlines():
        fields = line.split()
        if len(fields) == 3:
            try:
                symbols[fields[2]] = int(fields[0], 16)
            except ValueError:
                pass

    for name, address in EXPECTED.items():
        actual = symbols.get(name)
        assert actual == address, f"{name}: expected 0x{address:04X}, got {actual!r}"
    assert "bios_reset_stub" not in symbols

    source = (ROOT / "bios/EZ80BIOS.s").read_text()
    assert re.search(
        r"ld hl, bios_rst_vector_defaults\s+ld de, BIOS_ZERO\s+"
        r"ld bc, BIOS_RST_VECTOR_BYTES\s+ldir",
        source,
        re.IGNORECASE,
    ), "soft start must copy the RST template to address zero"
    assert re.search(r"\.set\s+BIOS_RST_VECTOR_BYTES,\s*0x40\b", source), (
        "the complete 0x40-byte RST map must be copied"
    )

    string_start = symbols["bios_loaded_message"]
    assert string_start > EXPECTED["bios_soft_start"], "constant strings must follow code entry"
    assert Path(ROOT / "bin/EZ80BIOS.bin").stat().st_size == 0x2000
    print("PASS: BIOS entry, IVT/state/stack/rings/templates/code addresses are compile-time fixed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
