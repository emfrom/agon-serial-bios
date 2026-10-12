ENTRY(bios_entry)

SECTIONS
{
    .bios 0x000000 :
    {
        KEEP(*(.bios))
        /* Keep the raw image addressable through the top of internal SRAM. */
        . = 0x00010000;
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}
