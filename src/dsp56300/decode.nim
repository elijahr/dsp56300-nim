## Clean-room MIT Motorola DSP56300 / DSP56311 Instruction Decoder
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import dsp56300/decode_types

func decodeReg3_1DD*(code: uint8): RegId {.inline.} =
  case (code and 0x7)
  of 0b100: RegId.regX0
  of 0b101: RegId.regX1
  of 0b110: RegId.regY0
  of 0b111: RegId.regY1
  else: RegId.regNone

func decodeReg3_DDD*(code: uint8): RegId {.inline.} =
  case (code and 0x7)
  of 0b000: RegId.regA0
  of 0b001: RegId.regB0
  of 0b010: RegId.regA2
  of 0b011: RegId.regB2
  of 0b100: RegId.regA1
  of 0b101: RegId.regB1
  of 0b110: RegId.regA
  of 0b111: RegId.regB
  else: RegId.regNone

func decodeReg3_TTT*(code: uint8): RegId {.inline.} =
  case (code and 0x7)
  of 0: RegId.regR0
  of 1: RegId.regR1
  of 2: RegId.regR2
  of 3: RegId.regR3
  of 4: RegId.regR4
  of 5: RegId.regR5
  of 6: RegId.regR6
  else: RegId.regR7

func decodeReg3_NNN*(code: uint8): RegId {.inline.} =
  case (code and 0x7)
  of 0: RegId.regN0
  of 1: RegId.regN1
  of 2: RegId.regN2
  of 3: RegId.regN3
  of 4: RegId.regN4
  of 5: RegId.regN5
  of 6: RegId.regN6
  else: RegId.regN7

func decodeReg3_FFF*(code: uint8): RegId {.inline.} =
  case (code and 0x7)
  of 0: RegId.regM0
  of 1: RegId.regM1
  of 2: RegId.regM2
  of 3: RegId.regM3
  of 4: RegId.regM4
  of 5: RegId.regM5
  of 6: RegId.regM6
  else: RegId.regM7

func decodeReg3_GGG*(code: uint8): RegId {.inline.} =
  case (code and 0x7)
  of 0b000: RegId.regSZ
  of 0b001: RegId.regSR
  of 0b010: RegId.regOMR
  of 0b011: RegId.regSP
  of 0b100: RegId.regSSH
  of 0b101: RegId.regSSL
  of 0b110: RegId.regLA
  of 0b111: RegId.regLC
  else: RegId.regNone

func decodeReg6*(code: uint8): RegId {.inline.} =
  ## Six-Bit Encoding for All On-Chip Registers (Table 12-13)
  let hi3 = (code shr 3) and 0x7
  let lo3 = code and 0x7
  case hi3
  of 0b000: # 0001DD
    if (code and 0b001100) == 0b000100:
      decodeReg3_1DD(code and 0x7 or 0b100)
    else: RegId.regNone
  of 0b001: # 001DDD
    decodeReg3_DDD(lo3)
  of 0b010: # 010TTT
    decodeReg3_TTT(lo3)
  of 0b011: # 011NNN
    decodeReg3_NNN(lo3)
  of 0b100: # 100FFF
    decodeReg3_FFF(lo3)
  of 0b101: # 101EEE
    if lo3 == 0b010: RegId.regEP else: RegId.regNone
  of 0b110: # 110VVV
    if lo3 == 0b000: RegId.regVBA
    elif lo3 == 0b001: RegId.regSC
    else: RegId.regNone
  of 0b111: # 111GGG
    decodeReg3_GGG(lo3)
  else: RegId.regNone

func decodeReg5_1*(code: uint8): RegId {.inline.} =
  ## Five-Bit Register Encoding 1 (Table 12-16) for Parallel Data Moves
  case (code and 0x1F)
  of 0b00100: RegId.regX0
  of 0b00101: RegId.regX1
  of 0b00110: RegId.regY0
  of 0b00111: RegId.regY1
  of 0b01000: RegId.regA0
  of 0b01001: RegId.regB0
  of 0b01010: RegId.regA2
  of 0b01011: RegId.regB2
  of 0b01100: RegId.regA1
  of 0b01101: RegId.regB1
  of 0b01110: RegId.regA
  of 0b01111: RegId.regB
  of 0b10000..0b10111: decodeReg3_TTT(code and 7) # R0-R7
  of 0b11000..0b11111: decodeReg3_NNN(code and 7) # N0-N7
  else: RegId.regNone

func decodeReg5_2*(code: uint8): RegId {.inline.} =
  ## Five-Bit Register Encoding 2 (Table 12-16) for MOVEC & Control Registers
  let c = code and 0x1F
  if c <= 7:
    return decodeReg3_FFF(c) # M0-M7
  case c
  of 0b01010: RegId.regEP
  of 0b10000: RegId.regVBA
  of 0b10001: RegId.regSC
  of 0b11000: RegId.regSZ
  of 0b11001: RegId.regSR
  of 0b11010: RegId.regOMR
  of 0b11011: RegId.regSP
  of 0b11100: RegId.regSSH
  of 0b11101: RegId.regSSL
  of 0b11110: RegId.regLA
  of 0b11111: RegId.regLC
  else: RegId.regNone

func decodeAddrMode*(mmm: uint8): AddrMode {.inline.} =
  case (mmm and 0x7)
  of 0b000: AddrMode.amPostDecN
  of 0b001: AddrMode.amPostIncN
  of 0b010: AddrMode.amPostDec
  of 0b011: AddrMode.amPostInc
  of 0b100: AddrMode.amNoUpdate
  of 0b101: AddrMode.amIndexedNoUpdate
  of 0b110: AddrMode.amAbsolute
  of 0b111: AddrMode.amPreDec
  else: AddrMode.amNoUpdate

func decodeXYDualMode*(mm: uint8): AddrMode {.inline.} =
  case (mm and 0x3)
  of 0b00: AddrMode.amNoUpdate
  of 0b01: AddrMode.amPostIncN
  of 0b10: AddrMode.amPostDec
  of 0b11: AddrMode.amPostInc
  else: AddrMode.amNoUpdate

func decodeXYReg*(code: uint8, isY: bool): RegId {.inline.} =
  case (code and 0x3)
  of 0b00: (if isY: RegId.regY0 else: RegId.regX0)
  of 0b01: (if isY: RegId.regY1 else: RegId.regX1)
  of 0b10: RegId.regA
  of 0b11: RegId.regB
  else: RegId.regNone

proc decodeParallelMove*(moveWord: uint16): ParallelMove =
  ## Decodes the 16-bit Data Bus Move Field (bits 23..8 of instruction)
  if moveWord == 0:
    return ParallelMove(kind: ParallelMoveKind.pmNone)

  # Check top bit 15 (bit 23 of 24-bit word)
  if (moveWord and 0x8000'u16) != 0:
    # 1 w mm ee ff W rr MM RRR
    let w = (moveWord shr 14) and 1
    let mm = (moveWord shr 12) and 3
    let ee = (moveWord shr 10) and 3
    let ff = (moveWord shr 8) and 3
    let bigW = (moveWord shr 7) and 1
    let rr = (moveWord shr 5) and 3
    let bigMM = (moveWord shr 3) and 3
    let rrr = moveWord and 7

    # If X uses R0..R3, Y uses R4..R7 (rr + 4), else Y uses R0..R3 (rr)
    let yRNum = if rrr < 4: uint8(rr + 4) else: uint8(rr)

    return ParallelMove(
      kind: ParallelMoveKind.pmXYDual,
      xWrite: w == 1,
      xReg: decodeXYReg(uint8(ee), isY = false),
      xMode: decodeXYDualMode(uint8(bigMM)),
      xRNum: uint8(rrr),
      yWrite: bigW == 1,
      yReg: decodeXYReg(uint8(ff), isY = true),
      yMode: decodeXYDualMode(uint8(mm)),
      yRNum: yRNum
    )

  # Check bits 15..14 (bits 23..22 of 24-bit word)
  let hi2 = (moveWord shr 14) and 3
  if hi2 == 0b01:
    # 0 1 d d s d d d W 1 M M M R R R (or W 0 a a a a a a)
    let s = (moveWord shr 11) and 1
    let d5 = ((moveWord shr 12) and 0b11) shl 3 or (moveWord shr 8 and 0b111)
    let isWrite = ((moveWord shr 7) and 1) == 1
    let isEa = ((moveWord shr 6) and 1) == 1
    let reg = decodeReg5_1(uint8(d5))
    let space = if s == 0: MemSpace.memX else: MemSpace.memY

    if isEa:
      let mmm = (moveWord shr 3) and 7
      let rrr = moveWord and 7
      let mode = if mmm == 0b110 and rrr == 0b100: AddrMode.amImmediate else: decodeAddrMode(uint8(mmm))


      if s == 0:
        return ParallelMove(
          kind: ParallelMoveKind.pmXMem,
          memSpace: space,
          isWrite: isWrite,
          memReg: reg,
          memMode: mode,
          memRNum: uint8(rrr),
          memAddr: 0
        )
      else:
        return ParallelMove(
          kind: ParallelMoveKind.pmYMem,
          memSpace: space,
          isWrite: isWrite,
          memReg: reg,
          memMode: mode,
          memRNum: uint8(rrr),
          memAddr: 0
        )
    else:
      let aa = moveWord and 0x3F
      if s == 0:
        return ParallelMove(
          kind: ParallelMoveKind.pmXMem,
          memSpace: space,
          isWrite: isWrite,
          memReg: reg,
          memMode: AddrMode.amAbsolute,
          memRNum: 0,
          memAddr: uint32(aa)
        )
      else:
        return ParallelMove(
          kind: ParallelMoveKind.pmYMem,
          memSpace: space,
          isWrite: isWrite,
          memReg: reg,
          memMode: AddrMode.amAbsolute,
          memRNum: 0,
          memAddr: uint32(aa)
        )

  # hi2 == 0b00:
  # Check if top byte is 0x20:
  # 0010 0000 0010 CCCC -> IFcc
  # 0010 0000 0011 CCCC -> IFcc.U
  # 0010 0000 010M MRRR -> Address Register Update (U)
  let hiByte = uint8(moveWord shr 8)
  let loByte = uint8(moveWord and 0xFF)

  if hiByte == 0x20:
    if (loByte and 0xF0) == 0x20:
      return ParallelMove(kind: ParallelMoveKind.pmIfCc, cc: ConditionCode(loByte and 0xF), updateCcr: false)
    elif (loByte and 0xF0) == 0x30:
      return ParallelMove(kind: ParallelMoveKind.pmIfCc, cc: ConditionCode(loByte and 0xF), updateCcr: true)
    elif (loByte and 0b11100000) == 0b01000000:
      let mm = (loByte shr 3) and 3
      let rrr = loByte and 7
      return ParallelMove(kind: ParallelMoveKind.pmAddrUpdate, uMode: decodeXYDualMode(mm), uReg: rrr)

  # Check Immediate Short Move: 0 0 1 d d d d d i i i i i i i i
  # where ddddd != 00000
  if (moveWord and 0xE000'u16) == 0x2000'u16:
    let d5 = (moveWord shr 8) and 0x1F
    let imm = moveWord and 0xFF
    if d5 != 0:
      let dst = decodeReg5_1(uint8(d5))
      return ParallelMove(kind: ParallelMoveKind.pmImmediateShort, immShort: uint32(imm), immDst: dst)
    else:
      # d5 == 0: Register to register move: 0 0 1 0 0 0 e e e e e d d d d d
      let e5 = (moveWord shr 5) and 0x1F
      let dReg5 = moveWord and 0x1F
      return ParallelMove(
        kind: ParallelMoveKind.pmRegToReg,
        regSrc: decodeReg5_1(uint8(e5)),
        regDst: decodeReg5_1(uint8(dReg5))
      )

  # Check Register-to-Register where top 6 bits are 001000:
  if (moveWord and 0xFC00'u16) == 0x2000'u16:
    let e5 = (moveWord shr 5) and 0x1F
    let dReg5 = moveWord and 0x1F
    return ParallelMove(
      kind: ParallelMoveKind.pmRegToReg,
      regSrc: decodeReg5_1(uint8(e5)),
      regDst: decodeReg5_1(uint8(dReg5))
    )

  # Check X:R and R:Y moves (bits 15..12 = 0001)
  if (moveWord and 0xF000'u16) == 0x1000'u16:
    let bit7 = (moveWord shr 7) and 1
    if bit7 == 0:
      # X:R Class I: 0 0 0 1 f f d F W 0 M M M R R R
      let mmm = (moveWord shr 3) and 7
      let rrr = moveWord and 7
      let isWrite = ((moveWord shr 6) and 1) == 1
      return ParallelMove(
        kind: ParallelMoveKind.pmXR_ClassI,
        xrWrite: isWrite,
        xrXReg: RegId.regX0,
        xrMode: decodeAddrMode(uint8(mmm)),
        xrRNum: uint8(rrr),
        xrR2Src: RegId.regA,
        xrR2Dst: RegId.regB
      )
    else:
      # R:Y Class I: 0 0 0 1 d e f f W 1 M M M R R R
      let mmm = (moveWord shr 3) and 7
      let rrr = moveWord and 7
      let isWrite = ((moveWord shr 6) and 1) == 1
      return ParallelMove(
        kind: ParallelMoveKind.pmRY_ClassI,
        ryWrite: isWrite,
        ryYReg: RegId.regY0,
        ryMode: decodeAddrMode(uint8(mmm)),
        ryRNum: uint8(rrr),
        ryR1Src: RegId.regA,
        ryR1Dst: RegId.regB
      )

  # Check Class II X:R and R:Y moves: 0 0 0 0 1 0 0 d 0 0 M M M R R R
  if (moveWord and 0xFE00'u16) == 0x0800'u16:
    let d = (moveWord shr 8) and 1
    let isY = ((moveWord shr 7) and 1) == 1
    let mmm = (moveWord shr 3) and 7
    let rrr = moveWord and 7
    let acc = if d == 0: RegId.regA else: RegId.regB
    if not isY:
      return ParallelMove(kind: ParallelMoveKind.pmXR_ClassII, xr2Acc: acc, xr2Mode: decodeAddrMode(uint8(mmm)), xr2RNum: uint8(rrr))
    else:
      return ParallelMove(kind: ParallelMoveKind.pmRY_ClassII, ry2Acc: acc, ry2Mode: decodeAddrMode(uint8(mmm)), ry2RNum: uint8(rrr))

  return ParallelMove(kind: ParallelMoveKind.pmNone)

proc decodeInstruction*(words: openArray[uint32], pc: uint32): Instruction =
  ## Decodes 1-word or 2-word DSP56300 instruction starting at words[0].
  let w0 = words[0] and 0x00FFFFFF'u32
  let w1 = if words.len > 1: (words[1] and 0x00FFFFFF'u32) else: 0'u32

  var inst = Instruction(words: 1, pAddr: pc)

  # 1. Exact Single-Word System & Flow Control Instructions
  case w0
  of 0x000000'u32:
    inst.aluOp = AluOp.opNop
    return inst
  of 0x000004'u32:
    inst.ctrlOp = ControlOp.ctrlRti
    return inst
  of 0x000005'u32:
    inst.ctrlOp = ControlOp.ctrlIllegal
    return inst
  of 0x00000C'u32:
    inst.ctrlOp = ControlOp.ctrlRts
    return inst
  of 0x000084'u32:
    inst.ctrlOp = ControlOp.ctrlReset
    return inst
  of 0x000086'u32:
    inst.ctrlOp = ControlOp.ctrlWait
    return inst
  of 0x000087'u32:
    inst.ctrlOp = ControlOp.ctrlStop
    return inst
  of 0x00008C'u32:
    inst.ctrlOp = ControlOp.ctrlEndDo
    return inst
  else: discard

  # 2. Control Flow: JMP, Jcc, JSR, JScc, BRA, BSR, Bcc, BScc
  # JMP short: 0000 1100 0000 aaaa aaaaaaaa -> 0x0C0000 .. 0x0C0FFF
  if (w0 and 0xFFF000'u32) == 0x0C0000'u32:
    inst.ctrlOp = ControlOp.ctrlJmp
    inst.targetAddr = w0 and 0x0FFF'u32
    return inst

  # JSR short: 0000 1101 0000 aaaa aaaaaaaa -> 0x0D0000 .. 0x0D0FFF
  if (w0 and 0xFFF000'u32) == 0x0D0000'u32:
    inst.ctrlOp = ControlOp.ctrlJsr
    inst.targetAddr = w0 and 0x0FFF'u32
    return inst

  # Jcc short: 0000 1110 CCCC aaaa aaaaaaaa
  if (w0 and 0xFF0000'u32) == 0x0E0000'u32:
    inst.ctrlOp = ControlOp.ctrlJcc
    inst.cond = ConditionCode((w0 shr 12) and 0xF)
    inst.targetAddr = w0 and 0x0FFF'u32
    return inst

  # JScc short: 0000 1111 CCCC aaaa aaaaaaaa
  if (w0 and 0xFF0000'u32) == 0x0F0000'u32:
    inst.ctrlOp = ControlOp.ctrlJscc
    inst.cond = ConditionCode((w0 shr 12) and 0xF)
    inst.targetAddr = w0 and 0x0FFF'u32
    return inst

  # JMP ea: 0000 1010 11MM MRRR 1000 0000
  if (w0 and 0xFFC0FF'u32) == 0x0AC080'u32:
    inst.ctrlOp = ControlOp.ctrlJmp
    let mmm = (w0 shr 11) and 7
    let rrr = (w0 shr 8) and 7
    inst.mode = decodeAddrMode(uint8(mmm))
    inst.rNum = uint8(rrr)
    if inst.mode == AddrMode.amAbsolute:
      inst.words = 2
      inst.targetAddr = w1
    return inst

  # JSR ea: 0000 1011 11MM MRRR 1000 0000
  if (w0 and 0xFFC0FF'u32) == 0x0BC080'u32:
    inst.ctrlOp = ControlOp.ctrlJsr
    let mmm = (w0 shr 11) and 7
    let rrr = (w0 shr 8) and 7
    inst.mode = decodeAddrMode(uint8(mmm))
    inst.rNum = uint8(rrr)
    if inst.mode == AddrMode.amAbsolute:
      inst.words = 2
      inst.targetAddr = w1
    return inst


  # Jcc ea: 0000 1010 11MM MRRR 1010 CCCC
  if (w0 and 0xFFC0F0'u32) == 0x0AC0A0'u32:
    inst.ctrlOp = ControlOp.ctrlJcc
    inst.cond = ConditionCode(w0 and 0xF)
    let mmm = (w0 shr 11) and 7
    let rrr = (w0 shr 8) and 7
    inst.mode = decodeAddrMode(uint8(mmm))
    inst.rNum = uint8(rrr)
    if inst.mode == AddrMode.amAbsolute:
      inst.words = 2
      inst.targetAddr = w1
    return inst

  # JScc ea: 0000 1011 11MM MRRR 1010 CCCC
  if (w0 and 0xFFC0F0'u32) == 0x0BC0A0'u32:
    inst.ctrlOp = ControlOp.ctrlJscc
    inst.cond = ConditionCode(w0 and 0xF)
    let mmm = (w0 shr 11) and 7
    let rrr = (w0 shr 8) and 7
    inst.mode = decodeAddrMode(uint8(mmm))
    inst.rNum = uint8(rrr)
    if inst.mode == AddrMode.amAbsolute:
      inst.words = 2
      inst.targetAddr = w1
    return inst

  # BRA Short: 0000 0101 0000 11aa aa0a aaaa
  if (w0 and 0xFFF000'u32) == 0x050000'u32 and ((w0 shr 9) and 0b111) == 0b011:
    inst.ctrlOp = ControlOp.ctrlBra
    let a9 = ((w0 shr 6) and 0b1111) shl 5 or (w0 and 0x1F)
    let disp = if (a9 and 0x100) != 0: int32(a9 or 0xFFFFFE00'u32) else: int32(a9)
    inst.targetAddr = uint32(int32(pc) + disp)
    return inst

  # Hardware Loops: DO and REP
  # DO #xxx, expr: 0000 0110 iiii iiii 1000 hhhh
  if (w0 and 0xFF00F0'u32) == 0x060080'u32:
    inst.ctrlOp = ControlOp.ctrlDo
    let imm = ((w0 and 0xF) shl 8) or ((w0 shr 8) and 0xFF)
    inst.immValue = imm
    inst.words = 2
    inst.targetAddr = w1
    return inst

  # REP #xxx: 0000 0110 iiii iiii 1010 hhhh
  if (w0 and 0xFF00F0'u32) == 0x0600A0'u32:
    inst.ctrlOp = ControlOp.ctrlRep
    let imm = ((w0 and 0xF) shl 8) or ((w0 shr 8) and 0xFF)
    inst.immValue = imm
    return inst

  # DO FOREVER: 0000 0000 0000 0010 0000 0011 = 0x000203
  if w0 == 0x000203'u32:
    inst.ctrlOp = ControlOp.ctrlDoForever
    inst.words = 2
    inst.targetAddr = w1
    return inst

  # BRKcc: 0000 0000 0000 0010 0001 CCCC
  if (w0 and 0xFFFFF0'u32) == 0x000210'u32:
    inst.ctrlOp = ControlOp.ctrlBrkCc
    inst.cond = ConditionCode(w0 and 0xF)
    return inst

  # 3. Bit Manipulation: BSET, BCLR, BCHG, BTST
  # BSET / BCLR: 0000 1010 00aa aaaa 0S 1/0 0 bbbb
  # pp short: 0000 1010 10pp pppp 0S 1/0 0 bbbb
  if (w0 and 0xFF0000'u32) == 0x0A0000'u32:
    let mid = (w0 shr 8) and 0xFF
    let lo = w0 and 0xFF
    let isSet = ((lo shr 5) and 1) == 1
    let bitN = uint8(lo and 0x1F)
    let s = (lo shr 6) and 1
    inst.space = if s == 0: MemSpace.memX else: MemSpace.memY
    inst.bitNum = bitN
    inst.bitOp = if isSet: BitOpKind.bitSet else: BitOpKind.bitClr
    if (mid and 0xC0) == 0x80:
      # pp short
      inst.mode = AddrMode.amAbsolute
      inst.targetAddr = 0xFFFFC0'u32 or (mid and 0x3F)
    elif (mid and 0xC0) == 0x00:
      # aa short
      inst.mode = AddrMode.amAbsolute
      inst.targetAddr = mid and 0x3F
    else:
      # ea
      let mmm = (mid shr 3) and 7
      let rrr = mid and 7
      inst.mode = decodeAddrMode(uint8(mmm))
      inst.rNum = uint8(rrr)
      if inst.mode == AddrMode.amAbsolute:
        inst.words = 2
        inst.targetAddr = w1
    return inst

  # 4. Parallel Instruction: Data Bus Move Field (23..8) + Operation Code (7..0)
  let moveField = uint16((w0 shr 8) and 0xFFFF)
  let opcode = uint8(w0 and 0xFF)

  inst.parallel = decodeParallelMove(moveField)
  if inst.parallel.kind in {ParallelMoveKind.pmXMem, ParallelMoveKind.pmYMem}:
    if inst.parallel.memMode in {AddrMode.amAbsolute, AddrMode.amImmediate}:
      inst.words = 2
      inst.parallel.memAddr = w1


  # Check Opcode: Multiply vs Non-Multiply
  if (opcode and 0x80) != 0:
    # Multiply: 1 QQQ d k2 k1 k0
    let qqq = (opcode shr 4) and 7
    let d = (opcode shr 3) and 1
    let k2 = (opcode shr 2) and 1
    let k1 = (opcode shr 1) and 1
    let k0 = opcode and 1

    inst.dstReg = if d == 0: RegId.regA else: RegId.regB
    inst.isNegMpy = (k2 == 1)
    inst.isRounded = (k0 == 1)
    inst.aluOp = if k1 == 1:
      (if k0 == 1: AluOp.opMacr else: AluOp.opMac)
    else:
      (if k0 == 1: AluOp.opMpyr else: AluOp.opMpy)

    case qqq
    of 0b000:
      inst.src1Reg = RegId.regX0; inst.src2Reg = RegId.regX0
    of 0b001:
      inst.src1Reg = RegId.regY0; inst.src2Reg = RegId.regY0
    of 0b010:
      inst.src1Reg = RegId.regX1; inst.src2Reg = RegId.regX0
    of 0b011:
      inst.src1Reg = RegId.regY1; inst.src2Reg = RegId.regY0
    of 0b100:
      inst.src1Reg = RegId.regX0; inst.src2Reg = RegId.regY1
    of 0b101:
      inst.src1Reg = RegId.regY0; inst.src2Reg = RegId.regX0
    of 0b110:
      inst.src1Reg = RegId.regX1; inst.src2Reg = RegId.regY0
    of 0b111:
      inst.src1Reg = RegId.regY1; inst.src2Reg = RegId.regX1
    else: discard
  else:
    # Non-Multiply: 0 J J J D k k k
    let jjj = (opcode shr 4) and 7
    let d = (opcode shr 3) and 1
    let kkk = opcode and 7
    let dst = if d == 0: RegId.regA else: RegId.regB
    let otherAcc = if d == 0: RegId.regB else: RegId.regA
    inst.dstReg = dst

    case jjj
    of 0b000:
      case kkk
      of 0b000:
        inst.aluOp = if moveField != 0: AluOp.opMove else: AluOp.opNop
      of 0b001:
        inst.aluOp = AluOp.opTfr
        inst.src1Reg = otherAcc
      of 0b010:
        inst.aluOp = AluOp.opAddr
        inst.src1Reg = otherAcc
      of 0b011:
        inst.aluOp = AluOp.opTst
        inst.src1Reg = dst
      of 0b101:
        inst.aluOp = AluOp.opCmp
        inst.src1Reg = otherAcc
      of 0b110:
        inst.aluOp = AluOp.opSubr
        inst.src1Reg = otherAcc
      of 0b111:
        inst.aluOp = AluOp.opCmpm
        inst.src1Reg = otherAcc
      else: discard

    of 0b001:
      case kkk
      of 0b000:
        inst.aluOp = AluOp.opAdd
        inst.src1Reg = otherAcc
      of 0b001:
        inst.aluOp = AluOp.opRnd
      of 0b010:
        inst.aluOp = AluOp.opAddl
        inst.src1Reg = otherAcc
      of 0b011:
        inst.aluOp = AluOp.opClr
      of 0b100:
        inst.aluOp = AluOp.opSub
        inst.src1Reg = otherAcc
      of 0b110:
        inst.aluOp = AluOp.opSubl
        inst.src1Reg = otherAcc
      of 0b111:
        inst.aluOp = AluOp.opNot
        inst.src1Reg = dst
      else: discard

    of 0b010:
      case kkk
      of 0b000:
        inst.aluOp = AluOp.opAdd
        inst.src1Reg = if d == 0: RegId.regX0 else: RegId.regX1
      of 0b001:
        inst.aluOp = AluOp.opAdc
        inst.src1Reg = if d == 0: RegId.regX0 else: RegId.regX1
      of 0b010:
        inst.aluOp = AluOp.opAsr
        inst.src1Reg = dst
      of 0b011:
        inst.aluOp = AluOp.opLsr
        inst.src1Reg = dst
      of 0b100:
        inst.aluOp = AluOp.opSub
        inst.src1Reg = if d == 0: RegId.regX0 else: RegId.regX1
      of 0b101:
        inst.aluOp = AluOp.opSbc
        inst.src1Reg = if d == 0: RegId.regX0 else: RegId.regX1
      of 0b110:
        inst.aluOp = AluOp.opAbs
        inst.src1Reg = dst
      of 0b111:
        inst.aluOp = AluOp.opRor
        inst.src1Reg = dst
      else: discard

    of 0b011:
      case kkk
      of 0b000:
        inst.aluOp = AluOp.opAdd
        inst.src1Reg = if d == 0: RegId.regY0 else: RegId.regY1
      of 0b001:
        inst.aluOp = AluOp.opAdc
        inst.src1Reg = if d == 0: RegId.regY0 else: RegId.regY1
      of 0b010:
        inst.aluOp = AluOp.opAsl
        inst.src1Reg = dst
      of 0b011:
        inst.aluOp = AluOp.opLsl
        inst.src1Reg = dst
      of 0b100:
        inst.aluOp = AluOp.opSub
        inst.src1Reg = if d == 0: RegId.regY0 else: RegId.regY1
      of 0b101:
        inst.aluOp = AluOp.opSbc
        inst.src1Reg = if d == 0: RegId.regY0 else: RegId.regY1
      of 0b110:
        inst.aluOp = AluOp.opNeg
        inst.src1Reg = dst
      of 0b111:
        inst.aluOp = AluOp.opRol
        inst.src1Reg = dst
      else: discard

    of 0b100..0b111:
      let srcReg = case jjj
      of 0b100: RegId.regX0
      of 0b101: RegId.regY0
      of 0b110: RegId.regX1
      else: RegId.regY1
      inst.src1Reg = srcReg

      case kkk
      of 0b000: inst.aluOp = AluOp.opAdd
      of 0b001: inst.aluOp = AluOp.opTfr
      of 0b010: inst.aluOp = AluOp.opOr
      of 0b011: inst.aluOp = AluOp.opEor
      of 0b100: inst.aluOp = AluOp.opSub
      of 0b101: inst.aluOp = AluOp.opCmp
      of 0b110: inst.aluOp = AluOp.opAnd
      of 0b111: inst.aluOp = AluOp.opCmpm
      else: discard
    else: discard

  return inst
