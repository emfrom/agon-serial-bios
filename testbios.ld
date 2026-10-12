ENTRY(testbios)

SECTIONS
{
    .bios 0x000000 :
    {
        KEEP(*(.bios))
    }

    .testbios 0x010000 :
    {
        KEEP(*(.testbios))
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}
