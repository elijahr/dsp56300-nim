# Tier T0 Unit Tests for Motorola DSP56311 6-Channel DMA Controller
# Hardware Reference: DSP56311UM Chapter 6, DSP56300FM Chapter 10

import std/unittest
import dsp56300/peripherals/dma

type MockMemory = object
  xMem: array[0x10000, uint32]
  yMem: array[0x10000, uint32]
  pMem: array[0x10000, uint32]

proc readMem(mem: var MockMemory, space: DmaMemorySpace, addressVal: uint32): uint32 =
  let a = addressVal and 0xFFFF'u32
  case space
  of dmsX:
    result = mem.xMem[a]
  of dmsY:
    result = mem.yMem[a]
  of dmsP:
    result = mem.pMem[a]
  of dmsReserved:
    result = 0'u32

proc writeMem(
    mem: var MockMemory, space: DmaMemorySpace, addressVal: uint32, val: uint32
) =
  let a = addressVal and 0xFFFF'u32
  case space
  of dmsX:
    mem.xMem[a] = val and 0x00FFFFFF'u32
  of dmsY:
    mem.yMem[a] = val and 0x00FFFFFF'u32
  of dmsP:
    mem.pMem[a] = val and 0x00FFFFFF'u32
  of dmsReserved:
    discard

suite "DSP56311 6-Channel DMA Controller":
  test "Reset state matches hardware specification":
    var dma = newDmaController()
    check dma.readRegister(DMA_DSTR) == 0x000000'u32
    check dma.readRegister(DMA_DOR0) == 0x000000'u32
    check dma.readRegister(DMA_DOR1) == 0x000000'u32
    check dma.readRegister(DMA_DOR2) == 0x000000'u32
    check dma.readRegister(DMA_DOR3) == 0x000000'u32
    for ch in 0 .. 5:
      check dma.readRegister(dcrAddress(ch)) == 0x000000'u32
      check dma.readRegister(dsrAddress(ch)) == 0x000000'u32
      check dma.readRegister(ddrAddress(ch)) == 0x000000'u32
      check dma.readRegister(dcoAddress(ch)) == 0x000000'u32

  test "1D Block Transfer (DE-initiated, DTM=3, Postincrement)":
    var dma = newDmaController()
    var mem: MockMemory

    # Setup source data in X memory at 0x1000
    for i in 0 .. 3:
      mem.writeMem(dmsX, uint32(0x1000 + i), uint32(0xAA00 + i))

    # Channel 0: Source X:0x1000, Dest X:0x2000, Counter 4
    dma.writeRegister(dsrAddress(0), 0x001000'u32)
    dma.writeRegister(ddrAddress(0), 0x002000'u32)
    dma.writeRegister(dcoAddress(0), 3'u32) # Counter 3 -> 4 transfers (0..3)

    # DCR: DE=1 (bit 23), DIE=1 (bit 22), DTM=3 (bits 21..19 = 011b),
    # DAM source postinc (101b = 5), DAM dest postinc (101b = 5) -> DAM = 0x2D,
    # DDS=0 (X), DSS=0 (X)
    let dcrVal =
      (1'u32 shl 23) or (1'u32 shl 22) or (3'u32 shl 19) or (5'u32 shl 7) or
      (5'u32 shl 4)
    dma.writeRegister(dcrAddress(0), dcrVal)

    # Step DMA engine
    var stepped = dma.step(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        mem.readMem(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        mem.writeMem(space, a, val),
      proc(reqSource: int): bool =
        false,
    )
    check stepped

    # Verify all 4 words were transferred to 0x2000..0x2003
    for i in 0 .. 3:
      check mem.readMem(dmsX, uint32(0x2000 + i)) == uint32(0xAA00 + i)

    # Verify channel completed: DE cleared, Transfer Done set in DSTR, Interrupt asserted
    check (dma.readRegister(dcrAddress(0)) and (1'u32 shl 23)) == 0 # DE cleared
    check (dma.readRegister(DMA_DSTR) and DSTR_CHTD0) != 0
    check dma.isInterruptAsserted(0)

  test "2D Circular Buffer Transfer (Dual Counter Mode B with DOR0 offset)":
    var dma = newDmaController()
    var mem: MockMemory

    # Buffer length = 4 words. We transfer 8 words (2 cycles of 4 words).
    # Source at 0x3000 (8 consecutive words)
    for i in 0 .. 7:
      mem.writeMem(dmsX, uint32(0x3000 + i), uint32(0x100 + i))

    # Destination circular buffer at 0x4000 (length 4)
    # When DCOL wraps from 3 to 0, DDR should wrap back by adding DOR0 = -3
    dma.writeRegister(dsrAddress(1), 0x003000'u32)
    dma.writeRegister(ddrAddress(1), 0x004000'u32)

    # DCO: DCOH=1 (2 lines), DCOL=3 (4 words per line) -> (1 shl 12) or 3
    dma.writeRegister(dcoAddress(1), (1'u32 shl 12) or 3'u32)

    # DOR0 = -3 in 24-bit 2's complement = 0xFFFFFD
    dma.writeRegister(DMA_DOR0, 0xFFFFFD'u32)

    # DCR: DE=1 (bit 23), DTM=3 (DE-initiated block),
    # DAM source: postinc (101b = 5),
    # DAM dest: 2D with DOR0 (000b = 0) -> DAM = (0 shl 3) or 5 = 5
    let dcrVal = (1'u32 shl 23) or (3'u32 shl 19) or (0'u32 shl 7) or (5'u32 shl 4)
    dma.writeRegister(dcrAddress(1), dcrVal)

    # Step DMA engine to completion
    let stepped = dma.step(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        mem.readMem(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        mem.writeMem(space, a, val),
      proc(reqSource: int): bool =
        false,
    )
    check stepped

    # Destination buffer 0x4000..0x4003 was written twice:
    # First 4 words: 0x100..0x103
    # Second 4 words: overwritten with 0x104..0x107 due to circular DOR0 wrap!
    check mem.readMem(dmsX, 0x4000) == 0x104'u32
    check mem.readMem(dmsX, 0x4001) == 0x105'u32
    check mem.readMem(dmsX, 0x4002) == 0x106'u32
    check mem.readMem(dmsX, 0x4003) == 0x107'u32

  test "Peripheral request-triggered Word Transfer (DRS 11 = ESAI RX)":
    var dma = newDmaController()
    var mem: MockMemory
    var esaiRxReq = false

    mem.writeMem(dmsX, 0x5000, 0xCAFE01'u32)
    mem.writeMem(dmsX, 0x5001, 0xCAFE02'u32)

    # Channel 2: Source 0x5000, Dest 0x6000, Count 2
    dma.writeRegister(dsrAddress(2), 0x005000'u32)
    dma.writeRegister(ddrAddress(2), 0x006000'u32)
    dma.writeRegister(dcoAddress(2), 1'u32) # 2 transfers (0..1)

    # DCR: DE=1 (bit 23), DTM=1 (Word transfer on request),
    # DRS=11 (ESAI RX), DAM=both postinc (5, 5)
    let dcrVal =
      (1'u32 shl 23) or (1'u32 shl 19) or (11'u32 shl 11) or (5'u32 shl 7) or
      (5'u32 shl 4)
    dma.writeRegister(dcrAddress(2), dcrVal)

    # Step without request -> no transfer
    var stepped = dma.step(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        mem.readMem(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        mem.writeMem(space, a, val),
      proc(reqSource: int): bool =
        (reqSource == 11 and esaiRxReq),
    )
    check not stepped
    check mem.readMem(dmsX, 0x6000) == 0'u32

    # Assert ESAI RX request
    esaiRxReq = true
    stepped = dma.step(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        mem.readMem(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        mem.writeMem(space, a, val),
      proc(reqSource: int): bool =
        (reqSource == 11 and esaiRxReq),
    )
    check stepped
    check mem.readMem(dmsX, 0x6000) == 0xCAFE01'u32
    check mem.readMem(dmsX, 0x6001) == 0'u32 # second word not transferred yet
    check (dma.readRegister(dcrAddress(2)) and (1'u32 shl 23)) != 0
      # DE still 1 (1 word left)

    # Second request
    stepped = dma.step(
      proc(space: DmaMemorySpace, a: uint32): uint32 =
        mem.readMem(space, a),
      proc(space: DmaMemorySpace, a: uint32, val: uint32) =
        mem.writeMem(space, a, val),
      proc(reqSource: int): bool =
        (reqSource == 11 and esaiRxReq),
    )
    check stepped
    check mem.readMem(dmsX, 0x6001) == 0xCAFE02'u32
    check (dma.readRegister(dcrAddress(2)) and (1'u32 shl 23)) == 0
      # DE cleared on completion
    check (dma.readRegister(DMA_DSTR) and DSTR_CHTD2) != 0
