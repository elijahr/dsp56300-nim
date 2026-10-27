# Tier T0 Unit Tests for Motorola DSP56311 HDI08 Host Interface
# Hardware Reference: DSP56311UM Chapter 7, DSP56367UM Chapter 8

import std/unittest
import dsp56300/peripherals/hdi08

suite "DSP56311 HDI08 Host Interface":
  test "Reset state matches hardware specification":
    var hdi = newHdi08()
    # DSP-side reset state
    check hdi.readDspRegister(HCR_ADDR) == 0x000000'u32
    check hdi.readDspRegister(HSR_ADDR) == 0x000002'u32 # HTDE (bit 1) = 1
    check hdi.readDspRegister(HPCR_ADDR) == 0x000000'u32
    check hdi.readDspRegister(HBAR_ADDR) == 0x000080'u32

    # Host-side reset state
    check hdi.readHostRegister(ICR_ADDR) == 0x00'u8
    check hdi.readHostRegister(CVR_ADDR) == 0x00'u8
    check hdi.readHostRegister(ISR_ADDR) == 0x06'u8 # TXDE (bit 1) = 1, TRDY (bit 2) = 1
    check hdi.readHostRegister(IVR_ADDR) == 0x0F'u8

  test "Host-to-DSP 24-bit word transfer via TXH:TXM:TXL":
    var hdi = newHdi08()

    # Write high byte
    hdi.writeHostRegister(TXH_ADDR, 0x12'u8)
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HRDF) == 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_TXDE) != 0
    check not hdi.isDmaRxRequestAsserted()

    # Write middle byte
    hdi.writeHostRegister(TXM_ADDR, 0x34'u8)
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HRDF) == 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_TXDE) != 0

    # Write low byte (completes 24-bit word: 0x123456)
    hdi.writeHostRegister(TXL_ADDR, 0x56'u8)
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HRDF) != 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_TXDE) == 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_TRDY) == 0
    check hdi.isDmaRxRequestAsserted()

    # DSP reads HORX
    let dspWord = hdi.readDspRegister(HORX_ADDR)
    check dspWord == 0x123456'u32

    # Handshake flags should update
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HRDF) == 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_TXDE) != 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_TRDY) != 0
    check not hdi.isDmaRxRequestAsserted()

  test "DSP-to-Host 24-bit word transfer via HOTX to RXH:RXM:RXL":
    var hdi = newHdi08()

    # DSP writes 24-bit word 0xABCDEF to HOTX
    hdi.writeDspRegister(HOTX_ADDR, 0xABCDEF'u32)
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HTDE) == 0
    check (hdi.readHostRegister(ISR_ADDR) and ISR_RXDF) != 0
    check not hdi.isDmaTxRequestAsserted()

    # Host reads RXH
    check hdi.readHostRegister(RXH_ADDR) == 0xAB'u8
    check (hdi.readHostRegister(ISR_ADDR) and ISR_RXDF) != 0

    # Host reads RXM
    check hdi.readHostRegister(RXM_ADDR) == 0xCD'u8
    check (hdi.readHostRegister(ISR_ADDR) and ISR_RXDF) != 0

    # Host reads RXL (completes 24-bit read)
    check hdi.readHostRegister(RXL_ADDR) == 0xEF'u8
    check (hdi.readHostRegister(ISR_ADDR) and ISR_RXDF) == 0
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HTDE) != 0
    check hdi.isDmaTxRequestAsserted()

  test "Host Command Interrupt Vector triggering":
    var hdi = newHdi08()

    # Host writes CVR with HC=1 and Vector $12
    hdi.writeHostRegister(CVR_ADDR, 0x80'u8 or 0x12'u8)
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HCP) != 0
    check hdi.hasPendingHostCommand()

    # Vector address = $10 + 2 * HV
    check hdi.getHostCommandVector() == (0x10'u32 + 2 * 0x12'u32)

    # Acknowledge host command
    hdi.acknowledgeHostCommand()
    check (hdi.readDspRegister(HSR_ADDR) and HSR_HCP) == 0
    check not hdi.hasPendingHostCommand()
    check (hdi.readHostRegister(CVR_ADDR) and CVR_HC) == 0

  test "Host Flags synchronization (HF0..HF3)":
    var hdi = newHdi08()

    # Host sets HF0 and HF1 in ICR
    hdi.writeHostRegister(ICR_ADDR, ICR_HF0 or ICR_HF1)
    let hsr = hdi.readDspRegister(HSR_ADDR)
    check (hsr and HSR_HF0) != 0
    check (hsr and HSR_HF1) != 0

    # DSP sets HF2 and HF3 in HCR
    hdi.writeDspRegister(HCR_ADDR, HCR_HF2 or HCR_HF3)
    let isr = hdi.readHostRegister(ISR_ADDR)
    check (isr and ISR_HF2) != 0
    check (isr and ISR_HF3) != 0
