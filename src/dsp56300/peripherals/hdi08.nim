# Clean-room MIT implementation of Motorola DSP56311 / DSP56367 HDI08 Host Interface
# Hardware Reference: DSP56311UM Chapter 7, DSP56367UM Chapter 8

type
  Hdi08* = object
    # DSP-side registers (24-bit)
    hcr*: uint32     # Host Control Register
    hpcr*: uint32    # Host Port Control Register
    hbar*: uint32    # Host Base Address Register
    horx*: uint32    # Host Receive Data Register (read-only to DSP)
    hotx*: uint32    # Host Transmit Data Register (write-only by DSP)
    
    # Host-side registers (8-bit)
    icr*: uint8      # Interface Control Register
    cvr*: uint8      # Command Vector Register
    ivr*: uint8      # Interrupt Vector Register
    
    # Internal latches for 8-to-24 and 24-to-8 packing
    txHigh*: uint8
    txMid*: uint8
    txLow*: uint8
    rxHigh*: uint8
    rxMid*: uint8
    rxLow*: uint8

    # Handshake flags
    hrdf*: bool      # Host Receive Data Full (DSP has received word to read in HORX)
    htde*: bool      # Host Transmit Data Empty (DSP can write new word to HOTX)
    hcp*: bool       # Host Command Pending
    rxdf*: bool      # Receive Data Register Full (Host has received word from DSP to read in RXH/M/L)
    txde*: bool      # Transmit Data Register Empty (Host can write new word in TXH/M/L)
    trdy*: bool      # Transmitter Ready

# DSP-side Memory Map Equates
const
  HCR_ADDR*  = 0xFFFFC2'u32
  HSR_ADDR*  = 0xFFFFC3'u32
  HPCR_ADDR* = 0xFFFFC4'u32
  HBAR_ADDR* = 0xFFFFC5'u32
  HORX_ADDR* = 0xFFFFC6'u32
  HOTX_ADDR* = 0xFFFFC7'u32

  HDI08_HCR*  = HCR_ADDR
  HDI08_HSR*  = HSR_ADDR
  HDI08_HPCR* = HPCR_ADDR
  HDI08_HBAR* = HBAR_ADDR
  HDI08_HORX* = HORX_ADDR
  HDI08_HOTX* = HOTX_ADDR

# Host-side Register Address Offsets

const
  ICR_ADDR* = 0x00'u8
  CVR_ADDR* = 0x01'u8
  ISR_ADDR* = 0x02'u8
  IVR_ADDR* = 0x03'u8
  RXH_ADDR* = 0x05'u8
  RXM_ADDR* = 0x06'u8
  RXL_ADDR* = 0x07'u8
  TXH_ADDR* = 0x05'u8
  TXM_ADDR* = 0x06'u8
  TXL_ADDR* = 0x07'u8

# HCR Bit Masks
const
  HCR_HRIE* = 0x000001'u32
  HCR_HTIE* = 0x000002'u32
  HCR_HCIE* = 0x000004'u32
  HCR_HF2*  = 0x000008'u32
  HCR_HF3*  = 0x000010'u32
  HCR_HDM*  = 0x0000E0'u32

# HSR Bit Masks
const
  HSR_HRDF* = 0x000001'u32
  HSR_HTDE* = 0x000002'u32
  HSR_HCP*  = 0x000004'u32
  HSR_HF0*  = 0x000008'u32
  HSR_HF1*  = 0x000010'u32
  HSR_DMA*  = 0x000080'u32

# ICR Bit Masks
const
  ICR_RREQ* = 0x01'u8
  ICR_TREQ* = 0x02'u8
  ICR_HREC* = 0x04'u8
  ICR_HF0*  = 0x08'u8
  ICR_HF1*  = 0x10'u8
  ICR_HM0*  = 0x20'u8
  ICR_HM1*  = 0x40'u8
  ICR_INIT* = 0x80'u8

# CVR Bit Masks
const
  CVR_HV* = 0x3F'u8
  CVR_HC* = 0x80'u8

# ISR Bit Masks
const
  ISR_RXDF* = 0x01'u8
  ISR_TXDE* = 0x02'u8
  ISR_TRDY* = 0x04'u8
  ISR_HF2*  = 0x08'u8
  ISR_HF3*  = 0x10'u8
  ISR_DMA*  = 0x40'u8
  ISR_HREQ* = 0x80'u8

proc reset*(self: var Hdi08) =
  self.hcr = 0x000000'u32
  self.hpcr = 0x000000'u32
  self.hbar = 0x000080'u32
  self.horx = 0x000000'u32
  self.hotx = 0x000000'u32
  
  self.icr = 0x00'u8
  self.cvr = 0x00'u8
  self.ivr = 0x0F'u8

  self.txHigh = 0
  self.txMid = 0
  self.txLow = 0
  self.rxHigh = 0
  self.rxMid = 0
  self.rxLow = 0

  self.hrdf = false
  self.htde = true
  self.hcp = false
  self.rxdf = false
  self.txde = true
  self.trdy = true

proc newHdi08*(): Hdi08 =
  result.reset()

# DSP-side register access
proc readDspRegister*(self: var Hdi08, address: uint32): uint32 =
  case address
  of HCR_ADDR:
    result = self.hcr
  of HSR_ADDR:
    result = 0'u32
    if self.hrdf: result = result or HSR_HRDF
    if self.htde: result = result or HSR_HTDE
    if self.hcp:  result = result or HSR_HCP
    if (self.icr and ICR_HF0) != 0: result = result or HSR_HF0
    if (self.icr and ICR_HF1) != 0: result = result or HSR_HF1
    if (self.hcr and HCR_HDM) != 0: result = result or HSR_DMA
  of HPCR_ADDR:
    result = self.hpcr
  of HBAR_ADDR:
    result = self.hbar
  of HORX_ADDR:
    result = self.horx and 0x00FFFFFF'u32
    self.hrdf = false
    self.txde = true
    self.trdy = true
  of HOTX_ADDR:
    result = self.hotx and 0x00FFFFFF'u32
  else:
    result = 0'u32

proc writeDspRegister*(self: var Hdi08, address: uint32, value: uint32) =
  let val24 = value and 0x00FFFFFF'u32
  case address
  of HCR_ADDR:
    self.hcr = val24
  of HPCR_ADDR:
    self.hpcr = val24
  of HBAR_ADDR:
    self.hbar = val24
  of HOTX_ADDR:
    self.hotx = val24
    self.rxHigh = uint8((val24 shr 16) and 0xFF'u32)
    self.rxMid  = uint8((val24 shr 8)  and 0xFF'u32)
    self.rxLow  = uint8(val24 and 0xFF'u32)
    self.htde = false
    self.rxdf = true
  else:
    discard

# Host-side register access (MCF5307 / ColdFire bus)
proc readHostRegister*(self: var Hdi08, offset: uint8): uint8 =
  case offset
  of ICR_ADDR:
    result = self.icr
  of CVR_ADDR:
    result = self.cvr
  of ISR_ADDR:
    result = 0'u8
    if self.rxdf: result = result or ISR_RXDF
    if self.txde: result = result or ISR_TXDE
    if self.trdy: result = result or ISR_TRDY
    if (self.hcr and HCR_HF2) != 0: result = result or ISR_HF2
    if (self.hcr and HCR_HF3) != 0: result = result or ISR_HF3
    if (self.hcr and HCR_HDM) != 0: result = result or ISR_DMA
  of IVR_ADDR:
    result = self.ivr
  of RXH_ADDR:
    result = self.rxHigh
  of RXM_ADDR:
    result = self.rxMid
  of RXL_ADDR:
    result = self.rxLow
    self.rxdf = false
    self.htde = true
  else:
    result = 0'u8

proc writeHostRegister*(self: var Hdi08, offset: uint8, value: uint8) =
  case offset
  of ICR_ADDR:
    self.icr = value
    if (value and ICR_INIT) != 0:
      self.reset()
  of CVR_ADDR:
    self.cvr = value
    if (value and CVR_HC) != 0:
      self.hcp = true
  of IVR_ADDR:
    self.ivr = value
  of TXH_ADDR:
    self.txHigh = value
  of TXM_ADDR:
    self.txMid = value
  of TXL_ADDR:
    self.txLow = value
    self.horx = (uint32(self.txHigh) shl 16) or (uint32(self.txMid) shl 8) or uint32(self.txLow)
    self.hrdf = true
    self.txde = false
    self.trdy = false
  else:
    discard

# Command Vector & Interrupt Helpers
proc hasPendingHostCommand*(self: Hdi08): bool =
  self.hcp

proc getHostCommandVector*(self: Hdi08): uint32 =
  # Vector = $10 + 2 * HV
  let hv = uint32(self.cvr and CVR_HV)
  result = 0x10'u32 + 2'u32 * hv

proc acknowledgeHostCommand*(self: var Hdi08) =
  self.hcp = false
  self.cvr = self.cvr and (not CVR_HC)

# DMA Request line queries
proc isDmaRxRequestAsserted*(self: Hdi08): bool =
  # DRS 16: HDI08 Receive Data Full (HRDF = 1)
  self.hrdf

proc isDmaTxRequestAsserted*(self: Hdi08): bool =
  # DRS 17: HDI08 Transmit Data Empty (HTDE = 1)
  self.htde
