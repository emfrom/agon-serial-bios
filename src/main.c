#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <ez80f92.h>
#include <agon/mos.h>


static void delay_50ms(void)
{
    volatile uint32_t i;

    for (i = 0; i < 50000UL; i++) {
        __asm__("nop");
    }
}

#define ONCHIP_RAM_LOAD_BASE 0xB7E000UL
#define ONCHIP_RAM_EXEC_BASE 0x00E000UL
#define ONCHIP_RAM_SIZE 8192

void (*__enter_bios)(void) = (void (*)(void))ONCHIP_RAM_EXEC_BASE;

int main(void)
{
    /* Load BIOS into on chip RAM */
    FILE *f = fopen("EZ80BIOS.bin", "rb");
    if (NULL == f) {
        puts("Cannot open EZ80BIOS.bin");
        return EXIT_FAILURE;
    }

    if (ONCHIP_RAM_SIZE != fread((void *)ONCHIP_RAM_LOAD_BASE, 1,
                                 ONCHIP_RAM_SIZE, f)) {
        fprintf(stderr, "EZ80BIOS.bin must contain exactly %u bytes\n",
                ONCHIP_RAM_SIZE);
        fclose(f);
        return EXIT_FAILURE;
    }
    fclose(f);
    
    /* Starting MOS shutdown */
    puts("Closing MOS\n");
    delay_50ms();

    /* Send VDU 21 directly to the VDP through the MOS RST 10h vector. */
    __asm__ volatile (
        "ld a, 21\n\t"
        "rst 0x10"
        :
        :
        : "a"
    );
    delay_50ms();


    // CRITICAL: no MOS calls after this point


    // Turn of UART0. Also deasserts UART0 RTS (the output used for hardware flow control).
    IO(UART0_MCTL) = 0; 
    delay_50ms();

    //Leave interrupts off until BIOS has set it's stack up
    __asm__("di"); 
    
    /* Disable device-level interrupts */
    IO(UART0_IER) = 0x00;
    IO(UART1_IER) = 0x00;
    IO(TMR0_CTL) = 0x00;
    IO(TMR1_CTL) = 0x00;
    IO(TMR2_CTL) = 0x00;
    IO(TMR3_CTL) = 0x00;
    IO(TMR4_CTL) = 0x00;
    IO(TMR5_CTL) = 0x00;
    delay_50ms();



    /* Disable Flash memory-space access before remapping SRAM into page 0. */
    IO(FLASH_CTRL) &= (uint8_t)~0x08; // FLASH_EN = 0
    delay_50ms();
    
    /* F92 SRAM maps to {RAM_ADDR_U, 0xE000}..{RAM_ADDR_U, 0xFFFF}. */
    IO(RAM_ADDR_U) = 0x00;
    IO(RAM_CTL) |= 0x80;              // RAM_EN = 1; other bits are reserved
    delay_50ms();

    __enter_bios(); //Will never return

    return EXIT_FAILURE;
}

