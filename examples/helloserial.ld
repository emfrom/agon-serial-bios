ENTRY(helloserial)

SECTIONS
{
    .bios 0x000000 :
    {
        KEEP(*(.bios))
    }

    .helloserial 0x010000 :
    {
        KEEP(*(.helloserial))
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}
