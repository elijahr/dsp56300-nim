# Motorola DSP56311 Unified On-Chip Peripherals Subsystem
# Dispatches memory-mapped I/O and wires closed-circuit DMA request lines.
# Hardware Reference: DSP56311UM, DSP56367UM Table 5-2

import ./hdi08
import ./esai
import ./dma
import ./timers

export hdi08, esai, dma, timers

type
  Peripherals56311* = ref object
    hdi08*: Hdi08
    esai*: DualEsai
    dma*: DmaController
    timers*: TripleTimerModule
    readMem*: MemReader
    writeMem*: MemWriter
    extIrq*: array[4, bool] # IRQA..D

proc reset*(self: Peripherals56311) =
  self.hdi08.reset()
  self.esai.reset()
  self.dma.reset()
  self.timers.reset()
  for i in 0..3:
    self.extIrq[i] = false

proc newPeripherals56311*(): Peripherals56311 =
  new(result)
  result.reset()

proc setMemoryAccessors*(self: Peripherals56311, readProc: MemReader, writeProc: MemWriter) =
  self.readMem = readProc
  self.writeMem = writeProc

proc readX*(self: Peripherals56311, a: uint32): uint32 =
  let addr24 = a and 0x00FFFFFF'u32
  if addr24 >= 0xFFFF80'u32 and addr24 <= 0xFFFF8F'u32:
    result = self.timers.readRegister(addr24)
  elif addr24 >= 0xFFFFA0'u32 and addr24 <= 0xFFFFBC'u32:
    result = self.esai.readX(addr24)
  elif addr24 >= 0xFFFFC0'u32 and addr24 <= 0xFFFFC7'u32:
    result = self.hdi08.readDspRegister(addr24)
  elif addr24 >= 0xFFFFD0'u32 and addr24 <= 0xFFFFFF'u32:
    result = self.dma.readRegister(addr24)
  else:
    result = 0'u32

proc writeX*(self: Peripherals56311, a: uint32, val: uint32) =
  let addr24 = a and 0x00FFFFFF'u32
  if addr24 >= 0xFFFF80'u32 and addr24 <= 0xFFFF8F'u32:
    self.timers.writeRegister(addr24, val)
  elif addr24 >= 0xFFFFA0'u32 and addr24 <= 0xFFFFBC'u32:
    self.esai.writeX(addr24, val)
  elif addr24 >= 0xFFFFC0'u32 and addr24 <= 0xFFFFC7'u32:
    self.hdi08.writeDspRegister(addr24, val)
  elif addr24 >= 0xFFFFD0'u32 and addr24 <= 0xFFFFFF'u32:
    self.dma.writeRegister(addr24, val)

proc readY*(self: Peripherals56311, a: uint32): uint32 =
  let addr24 = a and 0x00FFFFFF'u32
  if (addr24 >= 0xFFFF80'u32 and addr24 <= 0xFFFF9C'u32) or (addr24 == 0xFFFFAF'u32):
    result = self.esai.readY(addr24)
  else:
    result = 0'u32

proc writeY*(self: Peripherals56311, a: uint32, val: uint32) =
  let addr24 = a and 0x00FFFFFF'u32
  if (addr24 >= 0xFFFF80'u32 and addr24 <= 0xFFFF9C'u32) or (addr24 == 0xFFFFAF'u32):
    self.esai.writeY(addr24, val)

proc hostRead8*(self: Peripherals56311, regOffset: uint8): uint8 =
  self.hdi08.readHostRegister(regOffset)

proc hostWrite8*(self: Peripherals56311, regOffset: uint8, val: uint8) =
  self.hdi08.writeHostRegister(regOffset, val)

proc queryDmaRequest*(self: Peripherals56311, reqSource: int): bool =
  case reqSource
  of 0..3:
    result = self.extIrq[reqSource]
  of 4..9:
    # DMA Ch 0..5 Done
    let ch = reqSource - 4
    result = (self.dma.dstr and (1'u32 shl (ch + 16))) != 0
  of 11: # ESAI 0 RX
    result = self.esai.isDmaRx0Asserted()
  of 12: # ESAI 0 TX
    result = self.esai.isDmaTx0Asserted()
  of 16: # HDI08 RX (Host transmitted data ready for DSP)
    result = self.hdi08.isDmaRxRequestAsserted()
  of 17: # HDI08 TX (DSP transmit register empty)
    result = self.hdi08.isDmaTxRequestAsserted()
  of 18: # Timer 0
    result = self.timers.isDmaRequestAsserted(0)
  of 19: # Timer 1
    result = self.timers.isDmaRequestAsserted(1)
  of 20: # Timer 2
    result = self.timers.isDmaRequestAsserted(2)
  of 21: # ESAI 1 RX
    result = self.esai.isDmaRx1Asserted()
  of 22: # ESAI 1 TX
    result = self.esai.isDmaTx1Asserted()
  else:
    result = false

proc step*(self: Peripherals56311, cycles: int = 1) =
  # Step Timers
  self.timers.step(cycles)

  # Step DMA Engine
  if self.readMem != nil and self.writeMem != nil:
    let rProc = self.readMem
    let wProc = self.writeMem
    discard self.dma.step(rProc, wProc, proc(src: int): bool = self.queryDmaRequest(src))

# ------------------------------------------------------------- C11 Export ABI

proc dsp56311_peripherals_create*(): pointer {.cdecl, exportc: "dsp56311_peripherals_create".} =
  let p = newPeripherals56311()
  GC_ref(p)
  result = cast[pointer](p)

proc dsp56311_peripherals_destroy*(p: pointer) {.cdecl, exportc: "dsp56311_peripherals_destroy".} =
  if p != nil:
    let peri = cast[Peripherals56311](p)
    GC_unref(peri)

proc dsp56311_peripherals_reset*(p: pointer) {.cdecl, exportc: "dsp56311_peripherals_reset".} =
  if p != nil:
    cast[Peripherals56311](p).reset()

proc dsp56311_peripherals_read_x*(p: pointer, addrVal: uint32): uint32 {.cdecl, exportc: "dsp56311_peripherals_read_x".} =
  if p != nil:
    result = cast[Peripherals56311](p).readX(addrVal)

proc dsp56311_peripherals_write_x*(p: pointer, addrVal: uint32, val: uint32) {.cdecl, exportc: "dsp56311_peripherals_write_x".} =
  if p != nil:
    cast[Peripherals56311](p).writeX(addrVal, val)

proc dsp56311_peripherals_read_y*(p: pointer, addrVal: uint32): uint32 {.cdecl, exportc: "dsp56311_peripherals_read_y".} =
  if p != nil:
    result = cast[Peripherals56311](p).readY(addrVal)

proc dsp56311_peripherals_write_y*(p: pointer, addrVal: uint32, val: uint32) {.cdecl, exportc: "dsp56311_peripherals_write_y".} =
  if p != nil:
    cast[Peripherals56311](p).writeY(addrVal, val)

proc dsp56311_peripherals_host_read8*(p: pointer, regOffset: uint8): uint8 {.cdecl, exportc: "dsp56311_peripherals_host_read8".} =
  if p != nil:
    result = cast[Peripherals56311](p).hostRead8(regOffset)

proc dsp56311_peripherals_host_write8*(p: pointer, regOffset: uint8, val: uint8) {.cdecl, exportc: "dsp56311_peripherals_host_write8".} =
  if p != nil:
    cast[Peripherals56311](p).hostWrite8(regOffset, val)

proc dsp56311_peripherals_step*(p: pointer, cycles: uint32) {.cdecl, exportc: "dsp56311_peripherals_step".} =
  if p != nil:
    cast[Peripherals56311](p).step(int(cycles))
