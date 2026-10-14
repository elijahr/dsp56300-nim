/* Tier T0 C11 ABI Test for DSP56311 Peripherals */

#include "dsp56300.h"
#include <stdio.h>
#include <assert.h>

/* Nim runtime initialization hook when linked statically */
extern void NimMain(void);

int main(void) {
    NimMain();

    printf("Testing DSP56311 Peripherals C11 ABI...\n");

    dsp56311_peripherals* peri = dsp56311_peripherals_create();
    assert(peri != NULL);

    /* 1. Reset state */
    dsp56311_peripherals_reset(peri);
    assert(dsp56311_peripherals_read_x(peri, 0xFFFF83) == 0); /* TPLR */
    assert(dsp56311_peripherals_read_x(peri, 0xFFFFC2) == 0); /* HCR */

    /* 2. Write and Read X-memory (Timer TPLR) */
    dsp56311_peripherals_write_x(peri, 0xFFFF83, 0x000007);
    assert(dsp56311_peripherals_read_x(peri, 0xFFFF83) == 0x000007);

    /* 3. Host-side 8-bit access (HDI08) */
    /* Write 3 bytes to TXH (0x05), TXM (0x06), TXL (0x07) */
    dsp56311_peripherals_host_write8(peri, 0x05, 0xDE);
    dsp56311_peripherals_host_write8(peri, 0x06, 0xAD);
    dsp56311_peripherals_host_write8(peri, 0x07, 0xBE);

    /* Read DSP-side HORX (0xFFFFC6) */
    uint32_t word = dsp56311_peripherals_read_x(peri, 0xFFFFC6);
    assert(word == 0xDEADBE);

    /* 4. Step clock cycles */
    dsp56311_peripherals_step(peri, 10);

    /* 5. Destroy */
    dsp56311_peripherals_destroy(peri);

    printf("DSP56311 Peripherals C11 ABI verified successfully!\n");
    return 0;
}
