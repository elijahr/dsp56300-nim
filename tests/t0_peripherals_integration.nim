# Tier T0 Integration Tests for Motorola DSP56311 Unified Peripherals Module
# Closed-circuit test: HDI08 Host Interface -> DMA Controller -> Dual ESAI -> Timers

import std/unittest
import dsp56300/peripherals/peripherals56311
import dsp56300/peripherals/hdi08
import dsp56300/peripherals/esai
import dsp56300/peripherals/dma
import dsp56300/peripherals/timers

type SystemRam = object
  xMem: array[0x10000, uint32]
  yMem: array[0x10000, uint32]
  pMem: array[0x10000, uint32]

proc readRam(ram: var SystemRam, space: DmaMemorySpace, a: uint32): uint32 =
  let addr16 = a and 0xFFFF'u32
  case space
  of dmsX:
    result = ram.xMem[addr16]
  of dmsY:
    result = ram.yMem[addr16]
  of dmsP:
    result = ram.pMem[addr16]
  of dmsReserved:
    result = 0'u32

proc writeRam(ram: var SystemRam, space: DmaMemorySpace, a: uint32, val: uint32) =
  let addr16 = a and 0xFFFF'u32
  case space
  of dmsX:
    ram.xMem[addr16] = val and 0x00FFFFFF'u32
  of dmsY:
    ram.yMem[addr16] = val and 0x00FFFFFF'u32
  of dmsP:
    ram.pMem[addr16] = val and 0x00FFFFFF'u32
  of dmsReserved:
    discard

suite "DSP56311 Unified Peripherals Subsystem":
  test "Memory-mapped address decoding across all peripheral blocks":
    var peri = newPeripherals56311()

    # 1. Timers in X-memory ($FFFF82..$FFFF8F)
    peri.writeX(TIMERS_TPLR, 0x123456'u32)
    check (peri.readX(TIMERS_TPLR) and TPLR_PL_MASK) == (0x123456'u32 and TPLR_PL_MASK)

    # 2. ESAI 0 in X-memory ($FFFFB3..$FFFFBC)
    peri.writeX(ESAI_TCR, 0x000100'u32)
    check peri.readX(ESAI_TCR) == 0x000100'u32

    # 3. HDI08 in X-memory ($FFFFC0..$FFFFC7)
    peri.writeX(HDI08_HCR, 0x000001'u32)
    check peri.readX(HDI08_HCR) == 0x000001'u32

    # 4. DMA in X-memory ($FFFFD0..$FFFFFF)
    peri.writeX(DMA_DOR0, 0x00FEED'u32)
    check peri.readX(DMA_DOR0) == 0x00FEED'u32

    # 5. ESAI 1 in Y-memory ($FFFF80..$FFFF9C)
    peri.writeY(ESAI1_TCR, 0x000200'u32)
    check peri.readY(ESAI1_TCR) == 0x000200'u32

  test "Closed-circuit dataflow: Host Write (HDI08) -> DMA transfer -> Internal RAM":
    var peri = newPeripherals56311()
    var ram: SystemRam

    # Connect RAM memory accessor callbacks to peripherals
    peri.setMemoryAccessors(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        if space == dmsX and a >= 0xFFFF80'u32:
          peri.readX(a)
        elif space == dmsY and a >= 0xFFFF80'u32:
          peri.readY(a)
        else:
          ram.readRam(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        if space == dmsX and a >= 0xFFFF80'u32:
          peri.writeX(a, val)
        elif space == dmsY and a >= 0xFFFF80'u32:
          peri.writeY(a, val)
        else:
          ram.writeRam(space, a, val),
    )

    # Host enables HDI08 transmit by writing 3 bytes to TXH, TXM, TXL
    # Word 1: 0x123456
    peri.hostWrite8(0x05, 0x12) # TXH
    peri.hostWrite8(0x06, 0x34) # TXM
    peri.hostWrite8(0x07, 0x56) # TXL
    # Now HDI08 HORX has 0x123456 and HRDF=1 -> DRS 16 is asserted!

    # Setup DMA Channel 0:
    # Source: HDI08 HORX (X:$FFFFC6), Dest: RAM X:0x1000, Counter 0 (1 word)
    peri.writeX(dsrAddress(0), HDI08_HORX)
    peri.writeX(ddrAddress(0), 0x001000'u32)
    peri.writeX(dcoAddress(0), 0'u32) # 1 transfer

    # DCR: DE=1 (bit 23), DTM=1 (word on req), DRS=16 (HDI08 RX),
    # DAM source: no inc (0), DAM dest: postinc (5) -> (0 shl 7) or (5 shl 4) = 0x50
    let dcrVal = (1'u32 shl 23) or (1'u32 shl 19) or (16'u32 shl 11) or 0x50'u32
    peri.writeX(dcrAddress(0), dcrVal)

    # Step peripheral engine (this checks DRS 16, fires DMA, reads HORX, writes RAM 0x1000)
    peri.step(1)

    # Verify word reached RAM 0x1000
    check ram.readRam(dmsX, 0x1000) == 0x123456'u32

    # Verify HDI08 HRDF is cleared because DMA read HORX
    check (peri.readX(HDI08_HSR) and HSR_HRDF) == 0

    # Verify DMA channel completed
    check (peri.readX(dcrAddress(0)) and (1'u32 shl 23)) == 0
    check (peri.readX(DMA_DSTR) and DSTR_CHTD0) != 0

  test "Closed-circuit dataflow: RAM -> DMA transfer -> Dual ESAI 0 TX":
    var peri = newPeripherals56311()
    var ram: SystemRam

    peri.setMemoryAccessors(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        if space == dmsX and a >= 0xFFFF80'u32:
          peri.readX(a)
        elif space == dmsY and a >= 0xFFFF80'u32:
          peri.readY(a)
        else:
          ram.readRam(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        if space == dmsX and a >= 0xFFFF80'u32:
          peri.writeX(a, val)
        elif space == dmsY and a >= 0xFFFF80'u32:
          peri.writeY(a, val)
        else:
          ram.writeRam(space, a, val),
    )

    # Enable ESAI 0 transmitter: TE0=1 (bit 0 of TCR)
    peri.writeX(ESAI_TCR, 1'u32)
    peri.esai.stepFrame()
    # TDE is 1 -> DRS 12 (ESAI 0 TX) is asserted!

    # Preload RAM at 0x2000 with audio sample 0x55AA11
    ram.writeRam(dmsX, 0x2000, 0x55AA11'u32)

    # Setup DMA Channel 1:
    # Source: RAM X:0x2000, Dest: ESAI TX0 (X:$FFFFA6), Counter 0 (1 word)
    peri.writeX(dsrAddress(1), 0x002000'u32)
    peri.writeX(ddrAddress(1), ESAI_TX0)
    peri.writeX(dcoAddress(1), 0'u32)
    # DCR: DE=1, DTM=1 (word on req), DRS=12 (ESAI TX), DAM src: postinc, DAM dest: no inc
    let dcrVal = (1'u32 shl 23) or (1'u32 shl 19) or (12'u32 shl 11) or (5'u32 shl 7)
    peri.writeX(dcrAddress(1), dcrVal)

    # Step peripheral engine: triggers DMA Ch 1, writes 0x55AA11 to ESAI TX0
    peri.step(1)

    # Verify ESAI TX0 has received the sample
    check peri.readX(ESAI_TX0) == 0x55AA11'u32
    # Verify DMA Ch 1 finished
    check (peri.readX(dcrAddress(1)) and (1'u32 shl 23)) == 0
