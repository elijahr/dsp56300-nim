# Clean-room MIT implementation of Motorola DSP56311 6-Channel DMA Controller
# Hardware Reference: DSP56311UM Chapter 6, DSP56300FM Chapter 10

type
  DmaMemorySpace* = enum
    dmsX = 0
    dmsY = 1
    dmsP = 2
    dmsReserved = 3

  DmaChannel* = object
    dsr*: uint32 # Source Address Register (24-bit)
    ddr*: uint32 # Destination Address Register (24-bit)
    dco*: uint32 # Counter Register (24-bit)
    dcr*: uint32 # Control Register (24-bit)

    # Preloaded counter values
    dcoPreload*: uint32
    dcolPreload*: uint32
    dcohPreload*: uint32

    # Active counter states
    curCount1D*: uint32
    dcolCur*: uint32
    dcohCur*: uint32

    interruptAsserted*: bool

  DmaController* = object
    channels*: array[6, DmaChannel]
    dor*: array[4, uint32] # DMA Offset Registers 0..3 (24-bit signed offsets)
    dstr*: uint32 # DMA Status Register

# DMA Shared Registers in X Memory
const
  DMA_DSTR* = 0xFFFFF4'u32
  DMA_DOR0* = 0xFFFFF3'u32
  DMA_DOR1* = 0xFFFFF2'u32
  DMA_DOR2* = 0xFFFFF1'u32
  DMA_DOR3* = 0xFFFFF0'u32

# DSTR Bit Definitions
const
  DSTR_CHTD0* = 0x000001'u32
  DSTR_CHTD1* = 0x000002'u32
  DSTR_CHTD2* = 0x000004'u32
  DSTR_CHTD3* = 0x000008'u32
  DSTR_CHTD4* = 0x000010'u32
  DSTR_CHTD5* = 0x000020'u32
  DSTR_CHACT0* = 0x000040'u32
  DSTR_CHACT1* = 0x000080'u32
  DSTR_CHACT2* = 0x000100'u32
  DSTR_CHACT3* = 0x000200'u32
  DSTR_CHACT4* = 0x000400'u32
  DSTR_CHACT5* = 0x000800'u32

# Address calculation helpers for channel registers
proc dcrAddress*(ch: int): uint32 =
  if ch in 0 .. 3:
    result = 0xFFFFEC'u32 - uint32(ch * 4)
  elif ch in 4 .. 5:
    result = 0xFFFFDC'u32 - uint32((ch - 4) * 4)
  else:
    result = 0'u32

proc dcoAddress*(ch: int): uint32 =
  dcrAddress(ch) + 1'u32

proc ddrAddress*(ch: int): uint32 =
  dcrAddress(ch) + 2'u32

proc dsrAddress*(ch: int): uint32 =
  dcrAddress(ch) + 3'u32

proc signExtend24(val: uint32): int64 =
  let v = uint64(val and 0x00FFFFFF'u32)
  if (v and 0x00800000'u64) != 0:
    result = cast[int64](v or 0xFFFFFFFFFF000000'u64)
  else:
    result = cast[int64](v)

proc reset*(self: var DmaController) =
  self.dstr = 0'u32
  for i in 0 .. 3:
    self.dor[i] = 0'u32
  for ch in 0 .. 5:
    self.channels[ch].dsr = 0'u32
    self.channels[ch].ddr = 0'u32
    self.channels[ch].dco = 0'u32
    self.channels[ch].dcr = 0'u32
    self.channels[ch].dcoPreload = 0'u32
    self.channels[ch].dcolPreload = 0'u32
    self.channels[ch].dcohPreload = 0'u32
    self.channels[ch].curCount1D = 0'u32
    self.channels[ch].dcolCur = 0'u32
    self.channels[ch].dcohCur = 0'u32
    self.channels[ch].interruptAsserted = false

proc newDmaController*(): DmaController =
  result.reset()

proc isInterruptAsserted*(self: DmaController, ch: int): bool =
  if ch in 0 .. 5:
    return self.channels[ch].interruptAsserted
  return false

proc clearInterrupt*(self: var DmaController, ch: int) =
  if ch in 0 .. 5:
    self.channels[ch].interruptAsserted = false

proc readRegister*(self: DmaController, address: uint32): uint32 =
  case address
  of DMA_DSTR:
    return self.dstr
  of DMA_DOR0:
    return self.dor[0] and 0x00FFFFFF'u32
  of DMA_DOR1:
    return self.dor[1] and 0x00FFFFFF'u32
  of DMA_DOR2:
    return self.dor[2] and 0x00FFFFFF'u32
  of DMA_DOR3:
    return self.dor[3] and 0x00FFFFFF'u32
  else:
    for ch in 0 .. 5:
      if address == dcrAddress(ch):
        return self.channels[ch].dcr
      if address == dcoAddress(ch):
        return self.channels[ch].dco
      if address == ddrAddress(ch):
        return self.channels[ch].ddr
      if address == dsrAddress(ch):
        return self.channels[ch].dsr
    return 0'u32

proc writeRegister*(self: var DmaController, address: uint32, value: uint32) =
  let val24 = value and 0x00FFFFFF'u32
  case address
  of DMA_DSTR:
    # Writing to DSTR: write 0 to CHTD bits clears them
    let mask = (val24 and 0x3F'u32)
    self.dstr = self.dstr and (not (mask xor 0x3F'u32))
  of DMA_DOR0:
    self.dor[0] = val24
  of DMA_DOR1:
    self.dor[1] = val24
  of DMA_DOR2:
    self.dor[2] = val24
  of DMA_DOR3:
    self.dor[3] = val24
  else:
    for ch in 0 .. 5:
      if address == dcrAddress(ch):
        self.channels[ch].dcr = val24
        # When DE is set from 0 to 1, initialize counter preloads
        if (val24 and (1'u32 shl 23)) != 0:
          self.channels[ch].curCount1D = self.channels[ch].dcoPreload
          self.channels[ch].dcolCur = self.channels[ch].dcolPreload
          self.channels[ch].dcohCur = self.channels[ch].dcohPreload
        return
      if address == dcoAddress(ch):
        self.channels[ch].dco = val24
        self.channels[ch].dcoPreload = val24
        self.channels[ch].dcolPreload = val24 and 0xFFF'u32
        self.channels[ch].dcohPreload = (val24 shr 12) and 0xFFF'u32
        self.channels[ch].curCount1D = val24
        self.channels[ch].dcolCur = self.channels[ch].dcolPreload
        self.channels[ch].dcohCur = self.channels[ch].dcohPreload
        return
      if address == ddrAddress(ch):
        self.channels[ch].ddr = val24
        return
      if address == dsrAddress(ch):
        self.channels[ch].dsr = val24
        return

type
  MemReader* = proc(space: DmaMemorySpace, a: uint32): uint32
  MemWriter* = proc(space: DmaMemorySpace, a: uint32, val: uint32)
  DmaReadProc* = MemReader
  DmaWriteProc* = MemWriter
  ReqChecker* = proc(reqSource: int): bool

proc executeWordTransfer(
    self: var DmaController, ch: int, reader: MemReader, writer: MemWriter
): bool =
  template c(): untyped =
    self.channels[ch]

  let dcr = c.dcr
  let dss = DmaMemorySpace(dcr and 3'u32)
  let dds = DmaMemorySpace((dcr shr 2) and 3'u32)
  let dam = (dcr shr 4) and 0x3F'u32
  let damSrc = dam and 7'u32
  let damDest = (dam shr 3) and 7'u32
  let d3d = (dcr and (1'u32 shl 10)) != 0
  let die = (dcr and (1'u32 shl 22)) != 0
  let dtm = (dcr shr 19) and 7'u32

  let is2D = (not d3d) and (damSrc < 4'u32 or damDest < 4'u32)

  # 1. Read word from source
  let dataWord = reader(dss, c.dsr)

  # 2. Write word to destination
  writer(dds, c.ddr, dataWord)

  # 3. Update counter and addresses
  var blockComplete = false

  if is2D:
    # 2D Mode (Dual Counter Mode B)
    let atEndOfLine = (c.dcolCur == 0)

    # Source Address Update
    if damSrc == 5'u32: # Postincrement by 1
      c.dsr = (c.dsr + 1'u32) and 0x00FFFFFF'u32
    elif damSrc < 4'u32: # 2D using DOR[damSrc]
      if not atEndOfLine:
        c.dsr = (c.dsr + 1'u32) and 0x00FFFFFF'u32
      else:
        let offset = signExtend24(self.dor[int(damSrc)])
        c.dsr = uint32((int64(c.dsr) + offset) and 0x00FFFFFF'i64)

    # Destination Address Update
    if damDest == 5'u32: # Postincrement by 1
      c.ddr = (c.ddr + 1'u32) and 0x00FFFFFF'u32
    elif damDest < 4'u32: # 2D using DOR[damDest]
      if not atEndOfLine:
        c.ddr = (c.ddr + 1'u32) and 0x00FFFFFF'u32
      else:
        let offset = signExtend24(self.dor[int(damDest)])
        c.ddr = uint32((int64(c.ddr) + offset) and 0x00FFFFFF'i64)

    # Counter decrement
    if c.dcolCur > 0:
      dec c.dcolCur
    else:
      if c.dcohCur > 0:
        dec c.dcohCur
        c.dcolCur = c.dcolPreload
      else:
        # Both DCOH and DCOL reached 0: block complete!
        blockComplete = true
        c.dcolCur = c.dcolPreload
        c.dcohCur = c.dcohPreload
  else:
    # 1D Mode (Single Counter Mode A)
    if damSrc == 5'u32:
      c.dsr = (c.dsr + 1'u32) and 0x00FFFFFF'u32
    if damDest == 5'u32:
      c.ddr = (c.ddr + 1'u32) and 0x00FFFFFF'u32

    if c.curCount1D > 0:
      dec c.curCount1D
    else:
      blockComplete = true
      c.curCount1D = c.dcoPreload

  # 4. Handle block completion
  if blockComplete:
    self.dstr = self.dstr or (1'u32 shl ch) # Set CHTD bit
    if die:
      c.interruptAsserted = true
    # Clear DE if in mode that clears DE
    if dtm in [0'u32, 1'u32, 2'u32, 3'u32]:
      c.dcr = c.dcr and (not (1'u32 shl 23))

  return true

proc step*(
    self: var DmaController,
    reader: MemReader,
    writer: MemWriter,
    reqChecker: ReqChecker,
): bool =
  result = false

  # Arbitration: priority levels 3 down to 0
  for prio in countdown(3, 0):
    for ch in 0 .. 5:
      template c(): untyped =
        self.channels[ch]

      let de = (c.dcr and (1'u32 shl 23)) != 0
      if not de:
        continue

      let chPrio = int((c.dcr shr 17) and 3'u32)
      if chPrio != prio:
        continue

      let dtm = (c.dcr shr 19) and 7'u32
      let drs = int((c.dcr shr 11) and 0x1F'u32)

      if dtm == 3'u32: # DE-initiated Block Transfer
        # Execute until block complete
        var safety = 0
        while (c.dcr and (1'u32 shl 23)) != 0 and safety < 100000:
          discard self.executeWordTransfer(ch, reader, writer)
          inc safety
        return true
      elif dtm == 1'u32 or dtm == 5'u32: # Word Transfer (request triggered)
        if reqChecker(drs):
          discard self.executeWordTransfer(ch, reader, writer)
          return true
      elif dtm == 0'u32 or dtm == 4'u32: # Block Transfer (request triggered)
        if reqChecker(drs):
          var safety = 0
          while (c.dcr and (1'u32 shl 23)) != 0 and safety < 100000:
            discard self.executeWordTransfer(ch, reader, writer)
            inc safety
          return true
