ENTRY(bios_entry)

SECTIONS
{
    .bios 0x000000 :
    {
        KEEP(*(.bios))
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}
