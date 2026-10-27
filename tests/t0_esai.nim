# Tier T0 Unit Tests for Motorola DSP56311 / DSP56367 Dual ESAI
# Hardware Reference: DSP56367UM Chapter 10 & 11

import std/unittest
import dsp56300/peripherals/esai

suite "Dual ESAI (Enhanced Serial Audio Interface)":
  test "Reset state matches hardware specification":
    var dualEsai = newDualEsai()

    # ESAI 0 (X Memory)
    check dualEsai.readX(ESAI_SAISR) == 0x000000'u32
    check dualEsai.readX(ESAI_TCR) == 0x000000'u32
    check dualEsai.readX(ESAI_RCR) == 0x000000'u32
    check not dualEsai.isDmaRx0Asserted()
    check not dualEsai.isDmaTx0Asserted()

    # ESAI 1 (Y Memory)
    check dualEsai.readY(ESAI1_SAISR) == 0x000000'u32
    check dualEsai.readY(ESAI1_TCR) == 0x000000'u32
    check dualEsai.readY(ESAI1_RCR) == 0x000000'u32
    check not dualEsai.isDmaRx1Asserted()
    check not dualEsai.isDmaTx1Asserted()

  test "ESAI 0 Transmit Data Empty (TDE) and DMA request DRS 12":
    var dualEsai = newDualEsai()

    # Enable transmitters 0, 1, 2 in TCR (TE0, TE1, TE2 = bits 0, 1, 2)
    dualEsai.writeX(ESAI_TCR, 0x000007'u32)

    # Trigger audio frame step - moves TX registers to shift registers
    dualEsai.stepFrame()

    # TDE (bit 0) should be asserted in SAISR and DMA TX request (DRS 12) asserted
    check (dualEsai.readX(ESAI_SAISR) and SAISR_TDE) != 0
    check dualEsai.isDmaTx0Asserted()
    check not dualEsai.isDmaTx1Asserted() # ESAI 1 unaffected

    # Write TX0, TX1: TDE still set because TX2 is not yet written
    dualEsai.writeX(ESAI_TX0, 0x111111'u32)
    dualEsai.writeX(ESAI_TX1, 0x222222'u32)
    check (dualEsai.readX(ESAI_SAISR) and SAISR_TDE) != 0
    check dualEsai.isDmaTx0Asserted()

    # Write TX2: all enabled transmitters written -> TDE clears and DMA TX request deasserts
    dualEsai.writeX(ESAI_TX2, 0x333333'u32)
    check (dualEsai.readX(ESAI_SAISR) and SAISR_TDE) == 0
    check not dualEsai.isDmaTx0Asserted()

  test "ESAI 0 Receive Data Full (RDF) and DMA request DRS 11":
    var dualEsai = newDualEsai()

    # Enable receivers 0 and 1 in RCR (RE0, RE1 = bits 0, 1)
    dualEsai.writeX(ESAI_RCR, 0x000003'u32)

    # Provide external audio input samples for receivers 0 and 1
    dualEsai.setExternalRx0(0, 0x444444'u32)
    dualEsai.setExternalRx0(1, 0x555555'u32)

    # Step audio frame
    dualEsai.stepFrame()

    # RDF (bit 6) should be asserted and DMA RX request (DRS 11) asserted
    check (dualEsai.readX(ESAI_SAISR) and SAISR_RDF) != 0
    check dualEsai.isDmaRx0Asserted()
    check not dualEsai.isDmaRx1Asserted()

    # Read RX0: RDF remains set because RX1 is not yet read
    check dualEsai.readX(ESAI_RX0) == 0x444444'u32
    check (dualEsai.readX(ESAI_SAISR) and SAISR_RDF) != 0

    # Read RX1: all enabled receivers read -> RDF clears and DMA RX request deasserts
    check dualEsai.readX(ESAI_RX1) == 0x555555'u32
    check (dualEsai.readX(ESAI_SAISR) and SAISR_RDF) == 0
    check not dualEsai.isDmaRx0Asserted()

  test "ESAI 1 independent Y-memory mapping and DMA requests (DRS 21/22)":
    var dualEsai = newDualEsai()

    # Enable transmitter 0 and receiver 0 on ESAI 1 (Y memory)
    dualEsai.writeY(ESAI1_TCR, 0x000001'u32)
    dualEsai.writeY(ESAI1_RCR, 0x000001'u32)
    dualEsai.setExternalRx1(0, 0x998877'u32)

    dualEsai.stepFrame()

    # ESAI 1 flags and DMA requests asserted
    check (dualEsai.readY(ESAI1_SAISR) and SAISR_TDE) != 0
    check (dualEsai.readY(ESAI1_SAISR) and SAISR_RDF) != 0
    check dualEsai.isDmaTx1Asserted()
    check dualEsai.isDmaRx1Asserted()

    # ESAI 0 remains completely quiet
    check not dualEsai.isDmaTx0Asserted()
    check not dualEsai.isDmaRx0Asserted()

    # Service ESAI 1
    dualEsai.writeY(ESAI1_TX0, 0x123123'u32)
    check not dualEsai.isDmaTx1Asserted()

    check dualEsai.readY(ESAI1_RX0) == 0x998877'u32
    check not dualEsai.isDmaRx1Asserted()
