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

#define ONCHIP_RAM_BASE 0xFFE000UL
#define ONCHIP_MOS_BASE 0xFFE000UL
#define ONCHIP_RAM_SIZE 8192

void (*__enter_bios)(void) = (void (*)(void))ONCHIP_RAM_BASE;

int main(void)
{
    /* Load BIOS into on chip RAM */
    FILE *f = fopen("EZ80BIOS.bin", "rb");
    if (NULL == f) {
        puts("Cannot open EZ80BIOS.bin");
        return EXIT_FAILURE;
    }

    if (ONCHIP_RAM_SIZE != fread((void *)ONCHIP_MOS_BASE, 1,
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

    /* Disable VDI */
    // VDU 24 disables VDU interrupts via MOS before MOS is shut down.
    putchar(0x18);
    fflush(stdout);
    delay_50ms();

    // Deassert UART0 RTS (the output used for hardware flow control).
    IO(UART0_MCTL) &= (uint8_t)~0x02;
    delay_50ms();

    // CRITICAL: no MOS calls after this point

    /* Disable device-level interrupts before disabling CPU interrupts. */
    IO(UART0_IER) = 0x00;
    IO(TMR0_CTL) = 0x00;
    IO(TMR1_CTL) = 0x00;
    IO(TMR2_CTL) = 0x00;
    IO(TMR3_CTL) = 0x00;
    IO(TMR4_CTL) = 0x00;
    IO(TMR5_CTL) = 0x00;

    delay_50ms();


    //Leave interrupts off until BIOS has set it's stack up
    __asm__("di"); 
    
    /* Move On-Chip RAM */
    IO(RAM_ADDR_U) = 0xFF;            //Top of memory map
    IO(RAM_CTL) = IO(RAM_CTL) | 0xC0; //Ram enabled and default arbitration
    delay_50ms();

    __enter_bios(); //Will never return

    return EXIT_SUCCESS;
}

