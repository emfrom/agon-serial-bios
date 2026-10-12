ENTRY(xwasd)

SECTIONS
{
    .bios 0x000000 :
    {
        KEEP(*(.bios))
    }

    .xwasd 0x010000 :
    {
        KEEP(*(.xwasd))
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}
