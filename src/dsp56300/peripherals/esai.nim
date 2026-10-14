# Clean-room MIT implementation of Motorola DSP56311 / DSP56367 Dual ESAI
# Hardware Reference: DSP56367UM Chapter 10 & 11

type
  EsaiUnit* = object
    saisr*: uint32
    saicr*: uint32
    tcr*: uint32
    tccr*: uint32
    rcr*: uint32
    rccr*: uint32
    tsma*: uint32
    tsmb*: uint32
    rsma*: uint32
    rsmb*: uint32
    tsr*: uint32
    
    tx*: array[6, uint32]
    rx*: array[4, uint32]
    
    externalRx*: array[4, uint32]
    externalTx*: array[6, uint32]
    
    txWritten*: uint8
    rxRead*: uint8
    
    tde*: bool
    rdf*: bool

  DualEsai* = object
    esai0*: EsaiUnit  # Mapped in X Memory
    esai1*: EsaiUnit  # Mapped in Y Memory
    emuxr*: uint32    # Mux Pin Control Register (Y:$FFFFAF)

# ESAI 0 (X Memory) Register Equates
const
  ESAI_TX0*   = 0xFFFFA0'u32
  ESAI_TX1*   = 0xFFFFA1'u32
  ESAI_TX2*   = 0xFFFFA2'u32
  ESAI_TX3*   = 0xFFFFA3'u32
  ESAI_TX4*   = 0xFFFFA4'u32
  ESAI_TX5*   = 0xFFFFA5'u32
  ESAI_TSR*   = 0xFFFFA6'u32
  ESAI_RX0*   = 0xFFFFA8'u32
  ESAI_RX1*   = 0xFFFFA9'u32
  ESAI_RX2*   = 0xFFFFAA'u32
  ESAI_RX3*   = 0xFFFFAB'u32
  ESAI_SAISR* = 0xFFFFB3'u32
  ESAI_SAICR* = 0xFFFFB4'u32
  ESAI_TCR*   = 0xFFFFB5'u32
  ESAI_TCCR*  = 0xFFFFB6'u32
  ESAI_RCR*   = 0xFFFFB7'u32
  ESAI_RCCR*  = 0xFFFFB8'u32
  ESAI_TSMA*  = 0xFFFFB9'u32
  ESAI_TSMB*  = 0xFFFFBA'u32
  ESAI_RSMA*  = 0xFFFFBB'u32
  ESAI_RSMB*  = 0xFFFFBC'u32

# ESAI 1 (Y Memory) Register Equates
const
  ESAI1_TX0*   = 0xFFFF80'u32
  ESAI1_TX1*   = 0xFFFF81'u32
  ESAI1_TX2*   = 0xFFFF82'u32
  ESAI1_TX3*   = 0xFFFF83'u32
  ESAI1_TX4*   = 0xFFFF84'u32
  ESAI1_TX5*   = 0xFFFF85'u32
  ESAI1_TSR*   = 0xFFFF86'u32
  ESAI1_RX0*   = 0xFFFF88'u32
  ESAI1_RX1*   = 0xFFFF89'u32
  ESAI1_RX2*   = 0xFFFF8A'u32
  ESAI1_RX3*   = 0xFFFF8B'u32
  ESAI1_SAISR* = 0xFFFF93'u32
  ESAI1_SAICR* = 0xFFFF94'u32
  ESAI1_TCR*   = 0xFFFF95'u32
  ESAI1_TCCR*  = 0xFFFF96'u32
  ESAI1_RCR*   = 0xFFFF97'u32
  ESAI1_RCCR*  = 0xFFFF98'u32
  ESAI1_TSMA*  = 0xFFFF99'u32
  ESAI1_TSMB*  = 0xFFFF9A'u32
  ESAI1_RSMA*  = 0xFFFF9B'u32
  ESAI1_RSMB*  = 0xFFFF9C'u32
  ESAI1_EMUXR* = 0xFFFFAF'u32

# Status Register (SAISR) Bit Definitions
const
  SAISR_TDE* = 0x000001'u32  # Bit 0: Transmit Data Register Empty
  SAISR_TUE* = 0x000002'u32  # Bit 1: Transmit Underrun Error
  SAISR_TFS* = 0x000004'u32  # Bit 2: Transmit Frame Sync Flag
  SAISR_TFD* = 0x000008'u32  # Bit 3: Transmit Frame Direction Flag
  SAISR_RDF* = 0x000040'u32  # Bit 6: Receive Data Register Full
  SAISR_ROE* = 0x000080'u32  # Bit 7: Receive Overrun Error
  SAISR_RFS* = 0x000100'u32  # Bit 8: Receive Frame Sync Flag
  SAISR_RFD* = 0x000200'u32  # Bit 9: Receive Frame Direction Flag

proc reset*(unit: var EsaiUnit) =
  unit.saisr = 0'u32
  unit.saicr = 0'u32
  unit.tcr = 0'u32
  unit.tccr = 0'u32
  unit.rcr = 0'u32
  unit.rccr = 0'u32
  unit.tsma = 0xFFFF'u32
  unit.tsmb = 0xFFFF'u32
  unit.rsma = 0xFFFF'u32
  unit.rsmb = 0xFFFF'u32
  unit.tsr = 0'u32
  
  for i in 0..5:
    unit.tx[i] = 0'u32
    unit.externalTx[i] = 0'u32
  for i in 0..3:
    unit.rx[i] = 0'u32
    unit.externalRx[i] = 0'u32

  unit.txWritten = 0'u8
  unit.rxRead = 0'u8
  unit.tde = false
  unit.rdf = false

proc reset*(self: var DualEsai) =
  self.esai0.reset()
  self.esai1.reset()
  self.emuxr = 0'u32

proc newDualEsai*(): DualEsai =
  result.reset()

# Enabled transmitters bitmask (TE0..TE5 in TCR bits 0..5)
proc enabledTxMask(unit: EsaiUnit): uint8 =
  uint8(unit.tcr and 0x3F'u32)

# Enabled receivers bitmask (RE0..RE3 in RCR bits 0..3)
proc enabledRxMask(unit: EsaiUnit): uint8 =
  uint8(unit.rcr and 0x0F'u32)

proc readUnit(unit: var EsaiUnit, offset: uint32): uint32 =
  case offset
  of 0x00: # TX0
    result = unit.tx[0]
  of 0x01: # TX1
    result = unit.tx[1]
  of 0x02: # TX2
    result = unit.tx[2]
  of 0x03: # TX3
    result = unit.tx[3]
  of 0x04: # TX4
    result = unit.tx[4]
  of 0x05: # TX5
    result = unit.tx[5]
  of 0x06: # TSR
    result = unit.tsr
  of 0x08: # RX0
    result = unit.rx[0]
    unit.rxRead = unit.rxRead or 0x01'u8
    if (unit.rxRead and unit.enabledRxMask()) == unit.enabledRxMask():
      unit.rdf = false
  of 0x09: # RX1
    result = unit.rx[1]
    unit.rxRead = unit.rxRead or 0x02'u8
    if (unit.rxRead and unit.enabledRxMask()) == unit.enabledRxMask():
      unit.rdf = false
  of 0x0A: # RX2
    result = unit.rx[2]
    unit.rxRead = unit.rxRead or 0x04'u8
    if (unit.rxRead and unit.enabledRxMask()) == unit.enabledRxMask():
      unit.rdf = false
  of 0x0B: # RX3
    result = unit.rx[3]
    unit.rxRead = unit.rxRead or 0x08'u8
    if (unit.rxRead and unit.enabledRxMask()) == unit.enabledRxMask():
      unit.rdf = false
  of 0x13: # SAISR
    result = unit.saisr
    if unit.tde: result = result or SAISR_TDE
    if unit.rdf: result = result or SAISR_RDF
  of 0x14: # SAICR
    result = unit.saicr
  of 0x15: # TCR
    result = unit.tcr
  of 0x16: # TCCR
    result = unit.tccr
  of 0x17: # RCR
    result = unit.rcr
  of 0x18: # RCCR
    result = unit.rccr
  of 0x19: # TSMA
    result = unit.tsma
  of 0x1A: # TSMB
    result = unit.tsmb
  of 0x1B: # RSMA
    result = unit.rsma
  of 0x1C: # RSMB
    result = unit.rsmb
  else:
    result = 0'u32

proc writeUnit(unit: var EsaiUnit, offset: uint32, value: uint32) =
  let val24 = value and 0x00FFFFFF'u32
  case offset
  of 0x00..0x05: # TX0..TX5
    let idx = int(offset)
    unit.tx[idx] = val24
    unit.txWritten = unit.txWritten or (1'u8 shl idx)
    let enMask = unit.enabledTxMask()
    if enMask != 0 and (unit.txWritten and enMask) == enMask:
      unit.tde = false
  of 0x06: # TSR
    unit.tsr = val24
  of 0x13: # SAISR (read only / clear on write)
    discard
  of 0x14: # SAICR
    unit.saicr = val24
  of 0x15: # TCR
    unit.tcr = val24
  of 0x16: # TCCR
    unit.tccr = val24
  of 0x17: # RCR
    unit.rcr = val24
  of 0x18: # RCCR
    unit.rccr = val24
  of 0x19: # TSMA
    unit.tsma = val24
  of 0x1A: # TSMB
    unit.tsmb = val24
  of 0x1B: # RSMA
    unit.rsma = val24
  of 0x1C: # RSMB
    unit.rsmb = val24
  else:
    discard

# Frame stepping simulation for one EsaiUnit
proc stepFrameUnit(unit: var EsaiUnit) =
  let txEn = unit.enabledTxMask()
  if txEn != 0:
    for i in 0..5:
      if (txEn and (1'u8 shl i)) != 0:
        unit.externalTx[i] = unit.tx[i]
    unit.txWritten = 0'u8
    unit.tde = true # Transmit registers emptied into shift registers

  let rxEn = unit.enabledRxMask()
  if rxEn != 0:
    for i in 0..3:
      if (rxEn and (1'u8 shl i)) != 0:
        unit.rx[i] = unit.externalRx[i]
    unit.rxRead = 0'u8
    unit.rdf = true # Receive registers filled from shift registers

# Memory access - ESAI 0 in X Memory
proc readX*(self: var DualEsai, address: uint32): uint32 =
  if address >= 0xFFFFA0'u32 and address <= 0xFFFFBC'u32:
    let offset = address - 0xFFFFA0'u32
    return self.esai0.readUnit(offset)
  return 0'u32

proc writeX*(self: var DualEsai, address: uint32, value: uint32) =
  if address >= 0xFFFFA0'u32 and address <= 0xFFFFBC'u32:
    let offset = address - 0xFFFFA0'u32
    self.esai0.writeUnit(offset, value)

# Memory access - ESAI 1 in Y Memory
proc readY*(self: var DualEsai, address: uint32): uint32 =
  if address == ESAI1_EMUXR:
    return self.emuxr
  if address >= 0xFFFF80'u32 and address <= 0xFFFF9C'u32:
    let offset = address - 0xFFFF80'u32
    return self.esai1.readUnit(offset)
  return 0'u32

proc writeY*(self: var DualEsai, address: uint32, value: uint32) =
  if address == ESAI1_EMUXR:
    self.emuxr = value and 0x00FFFFFF'u32
  elif address >= 0xFFFF80'u32 and address <= 0xFFFF9C'u32:
    let offset = address - 0xFFFF80'u32
    self.esai1.writeUnit(offset, value)

proc readRegisterX*(self: var DualEsai, address: uint32): uint32 {.inline.} = self.readX(address)
proc writeRegisterX*(self: var DualEsai, address: uint32, value: uint32) {.inline.} = self.writeX(address, value)
proc readRegisterY*(self: var DualEsai, address: uint32): uint32 {.inline.} = self.readY(address)
proc writeRegisterY*(self: var DualEsai, address: uint32, value: uint32) {.inline.} = self.writeY(address, value)


# Audio Frame Step API (e.g. 96 kHz frame boundary)

proc stepFrame*(self: var DualEsai) =
  self.esai0.stepFrameUnit()
  self.esai1.stepFrameUnit()

# External audio I/O hooks
proc setExternalRx0*(self: var DualEsai, channel: int, sample: uint32) =
  if channel in 0..3:
    self.esai0.externalRx[channel] = sample and 0x00FFFFFF'u32

proc getExternalTx0*(self: DualEsai, channel: int): uint32 =
  if channel in 0..5:
    return self.esai0.externalTx[channel]
  return 0'u32

proc setExternalRx1*(self: var DualEsai, channel: int, sample: uint32) =
  if channel in 0..3:
    self.esai1.externalRx[channel] = sample and 0x00FFFFFF'u32

proc getExternalTx1*(self: DualEsai, channel: int): uint32 =
  if channel in 0..5:
    return self.esai1.externalTx[channel]
  return 0'u32

# DMA Request line queries
proc isDmaRx0Asserted*(self: DualEsai): bool =
  # DRS 11: ESAI Receive Data Full (RDF = 1)
  self.esai0.rdf

proc isDmaTx0Asserted*(self: DualEsai): bool =
  # DRS 12: ESAI Transmit Data Empty (TDE = 1)
  self.esai0.tde

proc isDmaRx1Asserted*(self: DualEsai): bool =
  # DRS 21: ESAI_1 Receive Data Full (RDF = 1)
  self.esai1.rdf

proc isDmaTx1Asserted*(self: DualEsai): bool =
  # DRS 22: ESAI_1 Transmit Data Empty (TDE = 1)
  self.esai1.tde
