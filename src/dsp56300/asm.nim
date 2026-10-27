## Clean-room MIT Motorola DSP56300 / DSP56311 Instruction Assembler
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import dsp56300/decode_types

func encodeReg5_1*(reg: RegId): uint8 {.inline.} =
  ## 5-bit register encoding for data moves (Table 12-16)
  case reg
  of RegId.regX0:
    0b00100
  of RegId.regX1:
    0b00101
  of RegId.regY0:
    0b00110
  of RegId.regY1:
    0b00111
  of RegId.regA0:
    0b01000
  of RegId.regB0:
    0b01001
  of RegId.regA2:
    0b01010
  of RegId.regB2:
    0b01011
  of RegId.regA1:
    0b01100
  of RegId.regB1:
    0b01101
  of RegId.regA:
    0b01110
  of RegId.regB:
    0b01111
  of RegId.regR0 .. RegId.regR7:
    uint8(0b10000 + (ord(reg) - ord(RegId.regR0)))
  of RegId.regN0 .. RegId.regN7:
    uint8(0b11000 + (ord(reg) - ord(RegId.regN0)))
  else:
    0

func encodeReg6*(reg: RegId): uint8 {.inline.} =
  ## 6-bit register encoding for all on-chip registers (Table 12-13)
  case reg
  of RegId.regX0:
    0b000100
  of RegId.regX1:
    0b000101
  of RegId.regY0:
    0b000110
  of RegId.regY1:
    0b000111
  of RegId.regA0:
    0b001000
  of RegId.regB0:
    0b001001
  of RegId.regA2:
    0b001010
  of RegId.regB2:
    0b001011
  of RegId.regA1:
    0b001100
  of RegId.regB1:
    0b001101
  of RegId.regA:
    0b001110
  of RegId.regB:
    0b001111
  of RegId.regR0 .. RegId.regR7:
    uint8(0b010000 + (ord(reg) - ord(RegId.regR0)))
  of RegId.regN0 .. RegId.regN7:
    uint8(0b011000 + (ord(reg) - ord(RegId.regN0)))
  of RegId.regM0 .. RegId.regM7:
    uint8(0b100000 + (ord(reg) - ord(RegId.regM0)))
  of RegId.regEP:
    0b101010
  of RegId.regVBA:
    0b110000
  of RegId.regSC:
    0b110001
  of RegId.regSZ:
    0b111000
  of RegId.regSR:
    0b111001
  of RegId.regOMR:
    0b111010
  of RegId.regSP:
    0b111011
  of RegId.regSSH:
    0b111100
  of RegId.regSSL:
    0b111101
  of RegId.regLA:
    0b111110
  of RegId.regLC:
    0b111111
  else:
    0

func encodeAddrMode*(mode: AddrMode): uint8 {.inline.} =
  case mode
  of AddrMode.amPostDecN: 0b000
  of AddrMode.amPostIncN: 0b001
  of AddrMode.amPostDec: 0b010
  of AddrMode.amPostInc: 0b011
  of AddrMode.amNoUpdate: 0b100
  of AddrMode.amIndexedNoUpdate: 0b101
  of AddrMode.amAbsolute: 0b110
  of AddrMode.amPreDec: 0b111
  else: 0b100

func encodeXYDualMode*(mode: AddrMode): uint8 {.inline.} =
  case mode
  of AddrMode.amNoUpdate: 0b00
  of AddrMode.amPostIncN: 0b01
  of AddrMode.amPostDec: 0b10
  of AddrMode.amPostInc: 0b11
  else: 0b00

func encodeXYReg*(reg: RegId): uint8 {.inline.} =
  case reg
  of RegId.regX0, RegId.regY0: 0b00
  of RegId.regX1, RegId.regY1: 0b01
  of RegId.regA: 0b10
  of RegId.regB: 0b11
  else: 0b00

# ------------------------------------------------------------- System & Flow Control

func asmNop*(): uint32 {.inline.} =
  0x000000'u32

func asmRts*(): uint32 {.inline.} =
  0x00000C'u32

func asmRti*(): uint32 {.inline.} =
  0x000004'u32

func asmReset*(): uint32 {.inline.} =
  0x000084'u32

func asmWait*(): uint32 {.inline.} =
  0x000086'u32

func asmStop*(): uint32 {.inline.} =
  0x000087'u32

func asmEndDo*(): uint32 {.inline.} =
  0x00008C'u32

func asmJmp*(targetAddr: uint32): uint32 {.inline.} =
  0x0C0000'u32 or (targetAddr and 0x0FFF'u32)

func asmJmpAbs*(targetAddr: uint32): array[2, uint32] {.inline.} =
  [0x0AF080'u32, targetAddr and 0x00FFFFFF'u32]

func asmJsr*(targetAddr: uint32): uint32 {.inline.} =
  0x0D0000'u32 or (targetAddr and 0x0FFF'u32)

func asmJsrAbs*(targetAddr: uint32): array[2, uint32] {.inline.} =
  [0x0BF080'u32, targetAddr and 0x00FFFFFF'u32]

func asmJcc*(cond: ConditionCode, targetAddr: uint32): uint32 {.inline.} =
  0x0E0000'u32 or ((uint32(ord(cond)) and 0x0F'u32) shl 12) or
    (targetAddr and 0x0FFF'u32)

func asmJccAbs*(cond: ConditionCode, targetAddr: uint32): array[2, uint32] {.inline.} =
  [0x0AF0A0'u32 or (uint32(ord(cond)) and 0x0F'u32), targetAddr and 0x00FFFFFF'u32]

# ------------------------------------------------------------- Hardware Loops

func asmDoImm*(count: uint16, endAddr: uint32): array[2, uint32] {.inline.} =
  let lo8 = uint32(count and 0xFF)
  let hi4 = uint32((count shr 8) and 0x0F)
  let w0 = 0x060080'u32 or (lo8 shl 8) or hi4
  result[0] = w0
  result[1] = endAddr and 0x00FFFFFF'u32

func asmRepImm*(count: uint16): uint32 {.inline.} =
  let lo8 = uint32(count and 0xFF)
  let hi4 = uint32((count shr 8) and 0x0F)
  return 0x0600A0'u32 or (lo8 shl 8) or hi4

# ------------------------------------------------------------- Data ALU Operations

func asmClr*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  # 0 001 D 011 -> 0x13 or 0x1B
  0x000013'u32 or (d shl 3)

func asmAdd*(src: RegId, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  if src in {RegId.regA, RegId.regB}:
    return 0x000010'u32 or (d shl 3)
  let jjj =
    case src
    of RegId.regX0: 0b100'u32
    of RegId.regY0: 0b101'u32
    of RegId.regX1: 0b110'u32
    else: 0b111'u32
  (jjj shl 4) or (d shl 3) or 0b000

func asmSub*(src: RegId, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  if src in {RegId.regA, RegId.regB}:
    return 0x000014'u32 or (d shl 3)
  let jjj =
    case src
    of RegId.regX0: 0b100'u32
    of RegId.regY0: 0b101'u32
    of RegId.regX1: 0b110'u32
    else: 0b111'u32
  (jjj shl 4) or (d shl 3) or 0b100

func asmAnd*(src: RegId, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  let jjj =
    case src
    of RegId.regX0: 0b100'u32
    of RegId.regY0: 0b101'u32
    of RegId.regX1: 0b110'u32
    else: 0b111'u32
  (jjj shl 4) or (d shl 3) or 0b110

func asmOr*(src: RegId, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  let jjj =
    case src
    of RegId.regX0: 0b100'u32
    of RegId.regY0: 0b101'u32
    of RegId.regX1: 0b110'u32
    else: 0b111'u32
  (jjj shl 4) or (d shl 3) or 0b010

func asmEor*(src: RegId, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  let jjj =
    case src
    of RegId.regX0: 0b100'u32
    of RegId.regY0: 0b101'u32
    of RegId.regX1: 0b110'u32
    else: 0b111'u32
  (jjj shl 4) or (d shl 3) or 0b011

func mpyEncodeQQQ(s1, s2: RegId): uint32 {.inline.} =
  if s1 == RegId.regX0 and s2 == RegId.regX0:
    0b000'u32
  elif s1 == RegId.regY0 and s2 == RegId.regY0:
    0b001'u32
  elif (s1 == RegId.regX1 and s2 == RegId.regX0) or
      (s1 == RegId.regX0 and s2 == RegId.regX1):
    0b010'u32
  elif (s1 == RegId.regY1 and s2 == RegId.regY0) or
      (s1 == RegId.regY0 and s2 == RegId.regY1):
    0b011'u32
  elif (s1 == RegId.regX0 and s2 == RegId.regY1) or
      (s1 == RegId.regY1 and s2 == RegId.regX0):
    0b100'u32
  elif (s1 == RegId.regY0 and s2 == RegId.regX0) or
      (s1 == RegId.regX0 and s2 == RegId.regY0):
    0b101'u32
  elif (s1 == RegId.regX1 and s2 == RegId.regY0) or
      (s1 == RegId.regY0 and s2 == RegId.regX1):
    0b110'u32
  elif (s1 == RegId.regY1 and s2 == RegId.regX1) or
      (s1 == RegId.regX1 and s2 == RegId.regY1):
    0b111'u32
  else:
    0b000'u32

func asmMpy*(s1, s2, dstAcc: RegId, neg: bool = false): uint32 {.inline.} =
  let qqq = mpyEncodeQQQ(s1, s2)
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  let k2 = if neg: 1'u32 else: 0'u32
  0x80'u32 or (qqq shl 4) or (d shl 3) or (k2 shl 2)

func asmMac*(s1, s2, dstAcc: RegId, neg: bool = false): uint32 {.inline.} =
  let qqq = mpyEncodeQQQ(s1, s2)
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  let k2 = if neg: 1'u32 else: 0'u32
  0x80'u32 or (qqq shl 4) or (d shl 3) or (k2 shl 2) or 0b010

func asmMacr*(s1, s2, dstAcc: RegId, neg: bool = false): uint32 {.inline.} =
  let qqq = mpyEncodeQQQ(s1, s2)
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  let k2 = if neg: 1'u32 else: 0'u32
  0x80'u32 or (qqq shl 4) or (d shl 3) or (k2 shl 2) or 0b011

func asmAsl*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  (0b011'u32 shl 4) or (d shl 3) or 0b010

func asmAsr*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  (0b010'u32 shl 4) or (d shl 3) or 0b010

func asmNeg*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  (0b011'u32 shl 4) or (d shl 3) or 0b110

func asmAbs*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  (0b010'u32 shl 4) or (d shl 3) or 0b110

func asmNot*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  (0b001'u32 shl 4) or (d shl 3) or 0b111

func asmTfr*(srcAcc, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  # jjj = 000, kkk = 001 -> 0x01 or 0x09
  0x000001'u32 or (d shl 3)

func asmTst*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  # jjj = 000, kkk = 011 -> 0x03 or 0x0B
  0x000003'u32 or (d shl 3)

func asmRnd*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  # jjj = 001, kkk = 001 -> 0x11 or 0x19
  0x000011'u32 or (d shl 3)

func asmCmp*(src: RegId, dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  if src in {RegId.regA, RegId.regB}:
    return 0x000005'u32 or (d shl 3)
  let jjj =
    case src
    of RegId.regX0: 0b100'u32
    of RegId.regY0: 0b101'u32
    of RegId.regX1: 0b110'u32
    else: 0b111'u32
  (jjj shl 4) or (d shl 3) or 0b101

func asmLsr*(dstAcc: RegId): uint32 {.inline.} =
  let d = if dstAcc == RegId.regB: 1'u32 else: 0'u32
  # jjj = 010, kkk = 011 -> 0x23 or 0x2B
  0x000023'u32 or (d shl 3)

# ------------------------------------------------------------- Moves & Memory Access

func asmMoveReg*(src, dst: RegId): uint32 {.inline.} =
  let e5 = uint32(encodeReg5_1(src))
  let d5 = uint32(encodeReg5_1(dst))
  let moveField = 0x2000'u32 or (e5 shl 5) or d5
  (moveField shl 8)

func asmMoveImmShort*(dst: RegId, imm8: uint8): uint32 {.inline.} =
  let d5 = uint32(encodeReg5_1(dst))
  let moveField = 0x2000'u32 or (d5 shl 8) or uint32(imm8)
  (moveField shl 8)

func asmMoveImm24*(dst: RegId, imm24: uint32): array[2, uint32] {.inline.} =
  let d5 = uint32(encodeReg5_1(dst))
  let hi = (d5 shr 3) and 3
  let lo = d5 and 7
  let s = 0'u32 # X-memory space
  let isWrite = 0'u32 # read from immediate to dst
  let isEa = 1'u32 # effective address / immediate
  let mmm = 0b110'u32 # 6
  let rrr = 0b100'u32 # 4 -> immediate data mode (Table 12-13)
  let moveField =
    (0b01'u32 shl 14) or (hi shl 12) or (s shl 11) or (lo shl 8) or (isWrite shl 7) or
    (isEa shl 6) or (mmm shl 3) or rrr
  result[0] = (moveField shl 8)
  result[1] = imm24 and 0x00FFFFFF'u32

func asmMoveMemAbs*(
    space: MemSpace, isWrite: bool, reg: RegId, addr16: uint32
): array[2, uint32] {.inline.} =
  let d5 = uint32(encodeReg5_1(reg))
  let hi = (d5 shr 3) and 3
  let lo = d5 and 7
  let s = if space == MemSpace.memY: 1'u32 else: 0'u32
  let w = if isWrite: 1'u32 else: 0'u32
  let isEa = 1'u32
  let mmm = 0b110'u32 # 6
  let rrr = 0b000'u32 # 0 -> absolute address (Table 12-13)
  let moveField =
    (0b01'u32 shl 14) or (hi shl 12) or (s shl 11) or (lo shl 8) or (w shl 7) or
    (isEa shl 6) or (mmm shl 3) or rrr
  result[0] = (moveField shl 8)
  result[1] = addr16 and 0x00FFFFFF'u32

func asmMoveMemInd*(
    space: MemSpace,
    isWrite: bool,
    reg: RegId,
    rNum: uint8,
    mode: AddrMode = AddrMode.amNoUpdate,
): uint32 {.inline.} =
  let d5 = uint32(encodeReg5_1(reg))
  let hi = (d5 shr 3) and 3
  let lo = d5 and 7
  let s = if space == MemSpace.memY: 1'u32 else: 0'u32
  let w = if isWrite: 1'u32 else: 0'u32
  let isEa = 1'u32
  let mmm = uint32(encodeAddrMode(mode))
  let rrr = uint32(rNum and 7)
  let moveField =
    (0b01'u32 shl 14) or (hi shl 12) or (s shl 11) or (lo shl 8) or (w shl 7) or
    (isEa shl 6) or (mmm shl 3) or rrr
  (moveField shl 8)

# ------------------------------------------------------------- Dual Parallel Moves

func asmParallelXY*(
    aluWord: uint32,
    xReg: RegId,
    xR: uint8,
    xInc: bool,
    yReg: RegId,
    yR: uint8,
    yInc: bool,
): uint32 {.inline.} =
  let w = 0'u32 # X read
  let mm = if yInc: 0b11'u32 else: 0b00'u32
  let ee = uint32(encodeXYReg(xReg))
  let ff = uint32(encodeXYReg(yReg))
  let bigW = 0'u32 # Y read
  let rrr = uint32(xR and 7)
  let rr =
    if rrr < 4:
      uint32((yR - 4) and 3)
    else:
      uint32(yR and 3)
  let bigMM = if xInc: 0b11'u32 else: 0b00'u32
  let moveWord =
    0x8000'u32 or (w shl 14) or (mm shl 12) or (ee shl 10) or (ff shl 8) or (bigW shl 7) or
    (rr shl 5) or (bigMM shl 3) or rrr
  (moveWord shl 8) or (aluWord and 0xFF'u32)
