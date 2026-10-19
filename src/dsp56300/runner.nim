## Clean-room MIT Motorola DSP56300 Cold-Block IR Runner
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import dsp56300/[decode_types, state, memory, agu, alu, ir]

proc getReg24*(s: var DspState, reg: RegId): uint32 {.inline.} =
  case reg
  of RegId.regX0: s.x0
  of RegId.regX1: s.x1
  of RegId.regY0: s.y0
  of RegId.regY1: s.y1
  of RegId.regA0: s.a0
  of RegId.regA1: s.a1
  of RegId.regA2: uint32(s.a2)
  of RegId.regB0: s.b0
  of RegId.regB1: s.b1
  of RegId.regB2: uint32(s.b2)
  of RegId.regA: limitAccumulator24(s.getAccA(), s.core.sr) # Data Shifter / Limiter read
  of RegId.regB: limitAccumulator24(s.getAccB(), s.core.sr)
  of RegId.regR0..RegId.regR7: s.r[int(reg) - int(RegId.regR0)]
  of RegId.regN0..RegId.regN7: s.n[int(reg) - int(RegId.regN0)]
  of RegId.regM0..RegId.regM7: s.m[int(reg) - int(RegId.regM0)]
  of RegId.regPC: s.pc
  of RegId.regSR: s.sr
  of RegId.regLA: s.core.la
  of RegId.regLC: s.core.lc
  else: 0'u32

proc getReg24*(s: DspState, reg: RegId): uint32 {.inline.} =
  var st = s
  getReg24(st, reg)

proc setReg24*(s: var DspState, reg: RegId, val: uint32) {.inline.} =
  let v = val and 0x00FFFFFF'u32
  case reg
  of RegId.regX0: s.x0 = v
  of RegId.regX1: s.x1 = v
  of RegId.regY0: s.y0 = v
  of RegId.regY1: s.y1 = v
  of RegId.regA0: s.a0 = v
  of RegId.regA1: s.a1 = v
  of RegId.regA2: s.a2 = uint8(v and 0xFF)
  of RegId.regB0: s.b0 = v
  of RegId.regB1: s.b1 = v
  of RegId.regB2: s.b2 = uint8(v and 0xFF)
  of RegId.regA:
    # 24-bit write to A clears A0 and sign-extends into A2
    s.a1 = v
    s.a0 = 0
    s.a2 = if (v and 0x00800000'u32) != 0: 0xFF'u8 else: 0x00'u8
  of RegId.regB:
    s.b1 = v
    s.b0 = 0
    s.b2 = if (v and 0x00800000'u32) != 0: 0xFF'u8 else: 0x00'u8
  of RegId.regR0..RegId.regR7: s.r[int(reg) - int(RegId.regR0)] = v
  of RegId.regN0..RegId.regN7: s.n[int(reg) - int(RegId.regN0)] = v
  of RegId.regM0..RegId.regM7: s.m[int(reg) - int(RegId.regM0)] = v
  of RegId.regPC: s.pc = v
  of RegId.regSR: s.sr = v
  of RegId.regLA: s.core.la = v
  of RegId.regLC: s.core.lc = v
  else: discard

proc evalCondition*(cc: ConditionCode, sr: uint32): bool {.inline.} =
  if cc == ConditionCode.ccLE:
    return ((sr and SR_Z) or (((sr shr 2) xor sr) and SR_V)) != 0
  if cc == ConditionCode.ccGE:
    return (((sr shr 2) xor sr) and SR_V) == 0
  if cc == ConditionCode.ccLT:
    return (((sr shr 2) xor sr) and SR_V) != 0
  if cc == ConditionCode.ccGT:
    return ((sr and SR_Z) or (((sr shr 2) xor sr) and SR_V)) == 0
  if cc == ConditionCode.ccEQ:
    return (sr and SR_Z) != 0
  if cc == ConditionCode.ccNE:
    return (sr and SR_Z) == 0
  case cc
  of ConditionCode.ccPL: (sr and SR_N) == 0
  of ConditionCode.ccMI: (sr and SR_N) != 0
  of ConditionCode.ccHS: (sr and SR_C) == 0
  of ConditionCode.ccLO: (sr and SR_C) != 0
  of ConditionCode.ccEC: (sr and SR_E) == 0
  of ConditionCode.ccES: (sr and SR_E) != 0
  of ConditionCode.ccLC: (sr and SR_L) == 0
  of ConditionCode.ccLS: (sr and SR_L) != 0
  of ConditionCode.ccNN: not (((sr and SR_Z) != 0) or (((sr and SR_U) != 0) and ((sr and SR_E) == 0)))
  of ConditionCode.ccNR: ((sr and SR_Z) != 0) or (((sr and SR_U) != 0) and ((sr and SR_E) == 0))
  else: false


proc runBlockCore*(state: var DspState, blk: var IrBasicBlock): uint32 =
  ## Reference deterministic execution oracle for a Micro-Op IR basic block.
  ## Returns the number of DSP instruction cycles executed.
  var cycles = 0'u32

  # Check loop repetition if entering with DO loop
  var loopIterations = 1'u32
  var isLoopBlock = false
  var loopEndPc = 0'u32

  # Check if block begins with a DO loop (skipping leading irCheckGen/irNop)
  for op in blk.ops:
    if op.kind == IrOpKind.irLoopDo:
      loopIterations = op.imm
      isLoopBlock = true
      loopEndPc = op.pAddr
      break
    elif op.kind != IrOpKind.irCheckGen and op.kind != IrOpKind.irNop:
      break

  let xRamPtr = if state.mem.xRam.len > 0: cast[ptr UncheckedArray[uint32]](addr state.mem.xRam[0]) else: nil
  let yRamPtr = if state.mem.yRam.len > 0: cast[ptr UncheckedArray[uint32]](addr state.mem.yRam[0]) else: nil
  let xLen = uint32(state.mem.xRam.len)

  let numOps = blk.ops.len
  if numOps == 0:
    if blk.hasCondBranch:
      cycles += 2
      if evalCondition(blk.branchCond, state.sr):
        state.pc = blk.branchTargetPc
      else:
        state.pc = blk.endPc
      return cycles
    elif blk.hasBranch:
      cycles += 2
      state.pc = blk.branchTargetPc
      return cycles
    return 0
  let opsPtr = cast[ptr UncheckedArray[MicroOp]](addr blk.ops[0])

  var accA = state.getAccA()
  var accB = state.getAccB()

  template syncAccState() =
    let uA = cast[uint64](accA)
    state.core.a2 = uint8((uA shr 48) and 0xFF'u64)
    state.core.a1 = uint32((uA shr 24) and 0x00FFFFFF'u64)
    state.core.a0 = uint32(uA and 0x00FFFFFF'u64)

    let uB = cast[uint64](accB)
    state.core.b2 = uint8((uB shr 48) and 0xFF'u64)
    state.core.b1 = uint32((uB shr 24) and 0x00FFFFFF'u64)
    state.core.b0 = uint32(uB and 0x00FFFFFF'u64)

  template readReg(r: RegId): uint32 =
    case r
    of RegId.regA: limitAccumulator24(accA, state.core.sr)
    of RegId.regA1: uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
    of RegId.regA0: uint32(cast[uint64](accA) and 0x00FFFFFF'u64)
    of RegId.regA2: uint32((cast[uint64](accA) shr 48) and 0xFF'u64)
    of RegId.regB: limitAccumulator24(accB, state.core.sr)
    of RegId.regB1: uint32((cast[uint64](accB) shr 24) and 0x00FFFFFF'u64)
    of RegId.regB0: uint32(cast[uint64](accB) and 0x00FFFFFF'u64)
    of RegId.regB2: uint32((cast[uint64](accB) shr 48) and 0xFF'u64)
    of RegId.regX0: state.x0
    of RegId.regX1: state.x1
    of RegId.regY0: state.y0
    of RegId.regY1: state.y1
    else: getReg24(state, r)

  for iter in 0..<loopIterations:
    for opIdx in 0..<numOps:
      template op: untyped = opsPtr[opIdx]

      case op.kind
      of IrOpKind.irNop:
        cycles += 1

      of IrOpKind.irCheckGen:
        let addrIdx = int(op.pAddr)
        if addrIdx < state.pRamGen.len:
          if state.pRamGen[addrIdx] != op.expectedGen:
            # Stale block! Abort execution
            syncAccState()
            return cycles

      of IrOpKind.irLoadImm:
        if op.dst == RegId.regA:
          accA = signExtend56(cast[uint64](int64(signExtend24(op.imm)) shl 24))
        elif op.dst == RegId.regB:
          accB = signExtend56(cast[uint64](int64(signExtend24(op.imm)) shl 24))
        else:
          setReg24(state, op.dst, op.imm)
          if unlikely(op.dst in {RegId.regA0, RegId.regA1, RegId.regA2}): accA = state.getAccA()
          elif unlikely(op.dst in {RegId.regB0, RegId.regB1, RegId.regB2}): accB = state.getAccB()

      of IrOpKind.irLoadReg:
        let v = readReg(op.src1)
        if op.dst == RegId.regA:
          accA = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
        elif op.dst == RegId.regB:
          accB = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
        else:
          setReg24(state, op.dst, v)
          if unlikely(op.dst in {RegId.regA0, RegId.regA1, RegId.regA2}): accA = state.getAccA()
          elif unlikely(op.dst in {RegId.regB0, RegId.regB1, RegId.regB2}): accB = state.getAccB()

      of IrOpKind.irStoreReg:
        let v = readReg(op.src1)
        if op.dst == RegId.regA:
          accA = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
        elif op.dst == RegId.regB:
          accB = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
        else:
          setReg24(state, op.dst, v)
          if unlikely(op.dst in {RegId.regA0, RegId.regA1, RegId.regA2}): accA = state.getAccA()
          elif unlikely(op.dst in {RegId.regB0, RegId.regB1, RegId.regB2}): accB = state.getAccB()

      of IrOpKind.irLoadMem:
        let targetAddr = if op.addrMode == AddrMode.amAbsolute:
          op.imm
        else:
          state.r[op.rNum]
        var val: uint32
        if likely(targetAddr < xLen):
          val = if op.space == MemSpace.memX: xRamPtr[targetAddr] else: yRamPtr[targetAddr]
        elif targetAddr >= 0xFFFF80'u32:
          let space = if op.space == MemSpace.memX: Dsp56300Space.SpaceX else: Dsp56300Space.SpaceY
          val = state.mem.readMem(state.core, space, targetAddr)
        if op.dst == RegId.regA:
          accA = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
        elif op.dst == RegId.regB:
          accB = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
        else:
          setReg24(state, op.dst, val)
          if unlikely(op.dst in {RegId.regA0, RegId.regA1, RegId.regA2}): accA = state.getAccA()
          elif unlikely(op.dst in {RegId.regB0, RegId.regB1, RegId.regB2}): accB = state.getAccB()

      of IrOpKind.irStoreMem:
        let targetAddr = if op.addrMode == AddrMode.amAbsolute:
          op.imm
        else:
          state.r[op.rNum]
        let val = readReg(op.src1)
        if likely(targetAddr < xLen):
          let maskedVal = val and 0x00FFFFFF'u32
          if op.space == MemSpace.memX:
            xRamPtr[targetAddr] = maskedVal
          else:
            yRamPtr[targetAddr] = maskedVal
        elif targetAddr >= 0xFFFF80'u32:
          let space = if op.space == MemSpace.memX: Dsp56300Space.SpaceX else: Dsp56300Space.SpaceY
          state.mem.writeMem(state.core, space, targetAddr, val)

      of IrOpKind.irAguUpdate:
        let delta: int32 = case op.addrMode
        of AddrMode.amPostInc: 1
        of AddrMode.amPostDec: -1
        of AddrMode.amPostIncN: int32(state.n[op.rNum])
        of AddrMode.amPostDecN: -int32(state.n[op.rNum])
        else: 0
        if delta != 0:
          let m = state.m[op.rNum]
          if likely((m and 0xFFFF'u32) == 0xFFFF'u32):
            state.r[op.rNum] = (uint32(int32(state.r[op.rNum]) + delta)) and 0x00FFFFFF'u32
          else:
            state.r[op.rNum] = agu.updateAddress(state.r[op.rNum], delta, m)

      of IrOpKind.irLoadXAbs:
        let val = xRamPtr[op.imm]
        if op.dst == RegId.regA:
          accA = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
        elif op.dst == RegId.regB:
          accB = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
        else:
          setReg24(state, op.dst, val)

      of IrOpKind.irLoadYAbs:
        let val = yRamPtr[op.imm]
        if op.dst == RegId.regA:
          accA = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
        elif op.dst == RegId.regB:
          accB = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
        else:
          setReg24(state, op.dst, val)

      of IrOpKind.irStoreXAbs:
        let val = readReg(op.src1)
        xRamPtr[op.imm] = val and 0x00FFFFFF'u32

      of IrOpKind.irStoreYAbs:
        let val = readReg(op.src1)
        yRamPtr[op.imm] = val and 0x00FFFFFF'u32

      of IrOpKind.irMacFast:
        cycles += 1
        let s1 = signExtend24(readReg(op.src1))
        let s2 = signExtend24(readReg(op.src2))
        var prod = (int64(s1) * int64(s2)) shl 1
        if op.isNeg: prod = -prod
        var acc = if op.dst == RegId.regB: accB else: accA
        acc = signExtend56(cast[uint64](acc + prod))
        if op.dst == RegId.regB: accB = acc else: accA = acc
        if acc == 0: state.core.sr = (state.core.sr or SR_Z) and (not SR_N)
        elif acc < 0: state.core.sr = (state.core.sr or SR_N) and (not SR_Z)
        else: state.core.sr = state.core.sr and (not (SR_Z or SR_N))

      of IrOpKind.irMpyFast:
        cycles += 1
        let s1 = signExtend24(readReg(op.src1))
        let s2 = signExtend24(readReg(op.src2))
        var prod = (int64(s1) * int64(s2)) shl 1
        if op.isNeg: prod = -prod
        let acc = signExtend56(cast[uint64](prod))
        if op.dst == RegId.regB: accB = acc else: accA = acc
        if acc == 0: state.core.sr = (state.core.sr or SR_Z) and (not SR_N)
        elif acc < 0: state.core.sr = (state.core.sr or SR_N) and (not SR_Z)
        else: state.core.sr = state.core.sr and (not (SR_Z or SR_N))

      of IrOpKind.irAddFast:
        cycles += 1
        let addVal = int64(signExtend24(readReg(op.src1))) shl 24
        var acc = if op.dst == RegId.regB: accB else: accA
        acc = signExtend56(cast[uint64](acc + addVal))
        if op.dst == RegId.regB: accB = acc else: accA = acc
        if acc == 0: state.core.sr = (state.core.sr or SR_Z) and (not SR_N)
        elif acc < 0: state.core.sr = (state.core.sr or SR_N) and (not SR_Z)
        else: state.core.sr = state.core.sr and (not (SR_Z or SR_N))

      of IrOpKind.irSubFast:
        cycles += 1
        let subVal = int64(signExtend24(readReg(op.src1))) shl 24
        var acc = if op.dst == RegId.regB: accB else: accA
        acc = signExtend56(cast[uint64](acc - subVal))
        if op.dst == RegId.regB: accB = acc else: accA = acc
        if acc == 0: state.core.sr = (state.core.sr or SR_Z) and (not SR_N)
        elif acc < 0: state.core.sr = (state.core.sr or SR_N) and (not SR_Z)
        else: state.core.sr = state.core.sr and (not (SR_Z or SR_N))

      of IrOpKind.irCmpFast:
        cycles += 1
        let subVal = int64(signExtend24(readReg(op.src1))) shl 24
        let acc = if op.dst == RegId.regB: accB else: accA
        let diff = signExtend56(cast[uint64](acc - subVal))
        if diff == 0: state.core.sr = (state.core.sr or SR_Z) and (not SR_N)
        elif diff < 0: state.core.sr = (state.core.sr or SR_N) and (not SR_Z)
        else: state.core.sr = state.core.sr and (not (SR_Z or SR_N))

      of IrOpKind.irClrFast:
        cycles += 1
        if op.dst == RegId.regB: accB = 0 else: accA = 0
        state.core.sr = (state.core.sr or SR_Z) and (not SR_N)

      of IrOpKind.irTfrFast:
        cycles += 1
        let acc = if op.src1 == RegId.regA: accA else: accB
        if op.dst == RegId.regB: accB = acc else: accA = acc
        if acc == 0: state.core.sr = (state.core.sr or SR_Z) and (not SR_N)
        elif acc < 0: state.core.sr = (state.core.sr or SR_N) and (not SR_Z)
        else: state.core.sr = state.core.sr and (not (SR_Z or SR_N))

      of IrOpKind.irAluOp:
        cycles += 1
        var acc = if op.dst == RegId.regB: accB else: accA


        case op.aluOp
        of AluOp.opMpy, AluOp.opMpyr:
          let s1 = signExtend24(readReg(op.src1))
          let s2 = signExtend24(readReg(op.src2))
          var prod = (int64(s1) * int64(s2)) shl 1
          if op.isNeg: prod = -prod
          acc = signExtend56(cast[uint64](prod))

        of AluOp.opMac, AluOp.opMacr:
          let s1 = signExtend24(readReg(op.src1))
          let s2 = signExtend24(readReg(op.src2))
          var prod = (int64(s1) * int64(s2)) shl 1
          if op.isNeg: prod = -prod
          acc = signExtend56(cast[uint64](acc + prod))

        of AluOp.opAdd:
          let addVal = if op.src1 == RegId.regA:
            accA
          elif op.src1 == RegId.regB:
            accB
          else:
            int64(signExtend24(readReg(op.src1))) shl 24 # Left-align 24-bit input to MSP (bits 47..24)
          acc = signExtend56(cast[uint64](acc + addVal))

        of AluOp.opSub:
          let subVal = if op.src1 == RegId.regA:
            accA
          elif op.src1 == RegId.regB:
            accB
          else:
            int64(signExtend24(readReg(op.src1))) shl 24
          acc = signExtend56(cast[uint64](acc - subVal))

        of AluOp.opClr:
          acc = 0

        of AluOp.opTfr:
          acc = if op.src1 == RegId.regA: accA else: accB

        of AluOp.opTst:
          discard

        of AluOp.opNeg:
          acc = signExtend56(cast[uint64](-acc))

        of AluOp.opAbs:
          if acc < 0: acc = signExtend56(cast[uint64](-acc))

        of AluOp.opAsl:
          let cOut = ((cast[uint64](acc) and (1'u64 shl 47)) != 0) or ((cast[uint64](acc) and (1'u64 shl 55)) != 0)
          acc = signExtend56(cast[uint64](acc shl 1))
          if cOut:
            state.sr = state.sr or SR_C
          else:
            state.sr = state.sr and (not SR_C)

        of AluOp.opAsr:
          acc = signExtend56(cast[uint64](acc shr 1))

        of AluOp.opLsr:
          acc = signExtend56((cast[uint64](acc) and 0x00FFFFFFFFFFFFFF'u64) shr 1)

        of AluOp.opCmp:
          let subVal = if op.src1 == RegId.regA:
            accA
          elif op.src1 == RegId.regB:
            accB
          else:
            int64(signExtend24(readReg(op.src1))) shl 24
          let diff = signExtend56(cast[uint64](acc - subVal))
          if diff == 0:
            state.sr = state.sr or SR_Z
          else:
            state.sr = state.sr and (not SR_Z)
          if diff < 0:
            state.sr = state.sr or SR_N
          else:
            state.sr = state.sr and (not SR_N)

        of AluOp.opAnd:
          let s1 = signExtend24(readReg(op.src1))
          acc = acc and (int64(s1) shl 24)

        of AluOp.opOr:
          let s1 = signExtend24(readReg(op.src1))
          acc = acc or (int64(s1) shl 24)

        of AluOp.opEor:
          let s1 = signExtend24(readReg(op.src1))
          acc = acc xor (int64(s1) shl 24)

        of AluOp.opNot:
          acc = not acc

        else: discard

        if op.aluOp != AluOp.opCmp:
          if op.dst == RegId.regB:
            accB = acc
          else:
            accA = acc

          # Update condition code flags in SR (Z and N)
          if acc == 0:
            state.sr = (state.sr or SR_Z) and (not SR_N)
          elif acc < 0:
            state.sr = (state.sr or SR_N) and (not SR_Z)
          else:
            state.sr = state.sr and (not (SR_Z or SR_N))

      of IrOpKind.irBranch:
        state.pc = op.imm
        cycles += 2
        syncAccState()
        return cycles

      of IrOpKind.irBranchCond:
        if evalCondition(op.cond, state.sr):
          state.pc = op.imm
        else:
          state.pc = blk.endPc
        cycles += 2
        syncAccState()
        return cycles

      of IrOpKind.irCall:
        state.core.stackPush(state.pc + 1, state.sr)
        state.pc = op.imm
        cycles += 2
        syncAccState()
        return cycles

      of IrOpKind.irReturn:
        var newPc, dummySr: uint32
        state.core.stackPop(newPc, dummySr)
        state.pc = newPc
        cycles += 2
        syncAccState()
        return cycles

      of IrOpKind.irReturnInt:
        var newPc, newSr: uint32
        state.core.stackPop(newPc, newSr)
        state.pc = newPc
        state.sr = newSr
        cycles += 2
        syncAccState()
        return cycles

      of IrOpKind.irLoopDo:
        state.core.lc = op.imm
        state.core.la = op.pAddr
        state.sr = state.sr or SR_LF
        cycles += 2

      of IrOpKind.irLoopEndDo:
        state.sr = state.sr and (not SR_LF)
        cycles += 1

      of IrOpKind.irLoopBrkCc:
        if evalCondition(op.cond, state.sr):
          state.sr = state.sr and (not SR_LF)
          state.pc = state.core.la + 1
          cycles += 2
          syncAccState()
          return cycles

      of IrOpKind.irLoopRep:
        state.core.repCount = op.imm
        state.core.repActive = true
        cycles += 1

      of IrOpKind.irLoopDoForever:
        state.core.la = op.pAddr
        state.sr = state.sr or SR_LF or SR_FV
        cycles += 2

      of IrOpKind.irHalt:
        state.core.halted = true
        cycles += 1
        syncAccState()
        return cycles

  if isLoopBlock:
    state.pc = loopEndPc + 1
    state.core.lc = 0
    state.sr = state.sr and (not SR_LF)
  elif blk.hasCondBranch:
    cycles += 2
    if evalCondition(blk.branchCond, state.sr):
      state.pc = blk.branchTargetPc
    else:
      state.pc = blk.endPc
  elif blk.hasBranch:
    cycles += 2
    state.pc = blk.branchTargetPc
  else:
    state.pc = blk.endPc

  if cycles == 0:
    cycles = 1

  syncAccState()
  return cycles

proc runBlock*(state: var DspState, blk: var IrBasicBlock): uint32 {.inline.} =
  runBlockCore(state, blk)

proc runBlock*(state: var DspState, blk: IrBasicBlock): uint32 {.inline.} =
  var b = blk
  runBlockCore(state, b)

proc runBlock*(state: var DspState, blk: ref IrBasicBlock): uint32 {.inline.} =
  if blk != nil:
    runBlockCore(state, blk[])
  else:
    0'u32

proc execFallbackOp(state: var DspState, op: ptr MicroOp): tuple[cycles: uint32, branched: bool] {.noinline.} =
  var accA = state.getAccA()
  var accB = state.getAccB()
  var sr = state.core.sr
  var pc = state.core.pc
  var la = state.core.la
  var lc = state.core.lc
  var cycles = 0'u32

  var regs: array[52, uint32]
  regs[int(RegId.regX0)] = state.core.x0
  regs[int(RegId.regX1)] = state.core.x1
  regs[int(RegId.regY0)] = state.core.y0
  regs[int(RegId.regY1)] = state.core.y1
  for idx in 0..7:
    regs[int(RegId.regR0) + idx] = state.core.r[idx]
    regs[int(RegId.regN0) + idx] = state.core.n[idx]
    regs[int(RegId.regM0) + idx] = state.core.m[idx]

  let xRamPtr = if state.mem.xRam.len > 0: cast[ptr UncheckedArray[uint32]](addr state.mem.xRam[0]) else: nil
  let yRamPtr = if state.mem.yRam.len > 0: cast[ptr UncheckedArray[uint32]](addr state.mem.yRam[0]) else: nil
  let xLen = uint32(state.mem.xRam.len)

  template syncAndReturn(didBranch: bool): untyped =
    let uA = cast[uint64](accA)
    state.core.a2 = uint8((uA shr 48) and 0xFF'u64)
    state.core.a1 = uint32((uA shr 24) and 0x00FFFFFF'u64)
    state.core.a0 = uint32(uA and 0x00FFFFFF'u64)

    let uB = cast[uint64](accB)
    state.core.b2 = uint8((uB shr 48) and 0xFF'u64)
    state.core.b1 = uint32((uB shr 24) and 0x00FFFFFF'u64)
    state.core.b0 = uint32(uB and 0x00FFFFFF'u64)

    state.core.pc = pc
    state.core.sr = sr
    state.core.la = la
    state.core.lc = lc
    state.core.x0 = regs[int(RegId.regX0)]
    state.core.x1 = regs[int(RegId.regX1)]
    state.core.y0 = regs[int(RegId.regY0)]
    state.core.y1 = regs[int(RegId.regY1)]
    for idx in 0..7:
      state.core.r[idx] = regs[int(RegId.regR0) + idx]
      state.core.n[idx] = regs[int(RegId.regN0) + idx]
      state.core.m[idx] = regs[int(RegId.regM0) + idx]

    return (cycles, didBranch)

  template updateCcrZN(acc: int64) =

    let uAcc = cast[uint64](acc)
    let zBit = (uint32(uAcc == 0)) shl 2
    let nBit = uint32((uAcc shr 60) and 8'u64)
    sr = (sr and (not 12'u32)) or zBit or nBit

  template limitAccFast(val: int64): uint32 =
    let u = cast[uint64](val)
    let sMode = (sr shr 10) and 0x03'u32
    if likely(sMode == 0):
      let top9 = (u shr 47) and 0x1FF'u64
      if likely(top9 == 0 or top9 == 0x1FF'u64):
        if ((u xor (u shl 1)) and (1'u64 shl 46)) != 0:
          sr = sr or SR_S
        uint32((u shr 24) and 0x00FFFFFF'u64)
      else:
        sr = sr or SR_L or SR_S
        if (u and (1'u64 shl 55)) == 0: 0x007FFFFF'u32 else: 0x00800000'u32
    else:
      limitAccumulator24(val, sr)

  template readRegFast(reg: RegId): uint32 =
    if reg <= RegId.regY1 or (reg >= RegId.regR0 and reg <= RegId.regM7):
      regs[int(reg)]
    elif reg == RegId.regA:
      limitAccFast(accA)
    elif reg == RegId.regB:
      limitAccFast(accB)
    elif reg == RegId.regA1:
      uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
    elif reg == RegId.regB1:
      uint32((cast[uint64](accB) shr 24) and 0x00FFFFFF'u64)
    elif reg == RegId.regA0:
      uint32(cast[uint64](accA) and 0x00FFFFFF'u64)
    elif reg == RegId.regB0:
      uint32(cast[uint64](accB) and 0x00FFFFFF'u64)
    elif reg == RegId.regA2:
      uint32((cast[uint64](accA) shr 48) and 0xFF'u64)
    elif reg == RegId.regB2:
      uint32((cast[uint64](accB) shr 48) and 0xFF'u64)
    elif reg == RegId.regSR:
      sr
    elif reg == RegId.regPC:
      pc
    elif reg == RegId.regLA:
      la
    elif reg == RegId.regLC:
      lc
    else:
      regs[int(reg)]

  template setRegFast(reg: RegId, val: uint32) =
    let v = val and 0x00FFFFFF'u32
    if reg <= RegId.regY1 or (reg >= RegId.regR0 and reg <= RegId.regM7):
      regs[int(reg)] = v
    elif reg == RegId.regA:
      accA = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
    elif reg == RegId.regB:
      accB = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
    elif reg == RegId.regA1:
      let uA = cast[uint64](accA)
      let low = uA and 0x00FFFFFF'u64
      let high = uA and 0xFF000000000000'u64
      let mid = uint64(v) shl 24
      accA = signExtend56(high or mid or low)
    elif reg == RegId.regB1:
      let uB = cast[uint64](accB)
      let low = uB and 0x00FFFFFF'u64
      let high = uB and 0xFF000000000000'u64
      let mid = uint64(v) shl 24
      accB = signExtend56(high or mid or low)
    elif reg == RegId.regA0:
      let uA = cast[uint64](accA)
      let upper = uA and (not 0x00FFFFFF'u64)
      accA = signExtend56(upper or uint64(v))
    elif reg == RegId.regB0:
      let uB = cast[uint64](accB)
      let upper = uB and (not 0x00FFFFFF'u64)
      accB = signExtend56(upper or uint64(v))
    elif reg == RegId.regA2:
      let uA = cast[uint64](accA)
      let lower = uA and 0x0000FFFFFFFFFFFF'u64
      let top = uint64(v and 0xFF'u32) shl 48
      accA = signExtend56(top or lower)
    elif reg == RegId.regB2:
      let uB = cast[uint64](accB)
      let lower = uB and 0x0000FFFFFFFFFFFF'u64
      let top = uint64(v and 0xFF'u32) shl 48
      accB = signExtend56(top or lower)
    elif reg == RegId.regSR:
      sr = v
    elif reg == RegId.regPC:
      pc = v
    elif reg == RegId.regLA:
      la = v
    elif reg == RegId.regLC:
      lc = v
    else:
      regs[int(reg)] = v

  case op.kind
  of IrOpKind.irNop, IrOpKind.irCheckGen:
    discard

  of IrOpKind.irLoadXAbs:
    let val = if op.imm < xLen: xRamPtr[op.imm]
              else: (state.core.sr = sr; state.mem.readMem(state.core, SpaceX, op.imm))
    if op.dst == RegId.regA:
      accA = cast[int64](cast[int32](val shl 8)) shl 16
    elif op.dst <= RegId.regY1:
      regs[int(op.dst)] = val
    elif op.dst == RegId.regB:
      accB = cast[int64](cast[int32](val shl 8)) shl 16
    else:
      setRegFast(op.dst, val)

  of IrOpKind.irLoadYAbs:
    let val = if op.imm < xLen: yRamPtr[op.imm]
              else: (state.core.sr = sr; state.mem.readMem(state.core, SpaceY, op.imm))
    if op.dst == RegId.regA:
      accA = cast[int64](cast[int32](val shl 8)) shl 16
    elif op.dst <= RegId.regY1:
      regs[int(op.dst)] = val
    elif op.dst == RegId.regB:
      accB = cast[int64](cast[int32](val shl 8)) shl 16
    else:
      setRegFast(op.dst, val)

  of IrOpKind.irStoreXAbs:
    let val = if op.src1 == RegId.regA1:
      uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
    elif op.src1 <= RegId.regY1:
      regs[int(op.src1)]
    elif op.src1 == RegId.regA:
      limitAccFast(accA)
    elif op.src1 == RegId.regB:
      limitAccFast(accB)
    else:
      readRegFast(op.src1) and 0x00FFFFFF'u32
    if likely(op.imm < xLen):
      xRamPtr[op.imm] = val
    else:
      state.core.sr = sr
      state.mem.writeMem(state.core, SpaceX, op.imm, val)

  of IrOpKind.irStoreYAbs:
    let val = if op.src1 == RegId.regA1:
      uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
    elif op.src1 <= RegId.regY1:
      regs[int(op.src1)]
    elif op.src1 == RegId.regA:
      limitAccFast(accA)
    elif op.src1 == RegId.regB:
      limitAccFast(accB)
    else:
      readRegFast(op.src1) and 0x00FFFFFF'u32
    if likely(op.imm < xLen):
      yRamPtr[op.imm] = val
    else:
      state.core.sr = sr
      state.mem.writeMem(state.core, SpaceY, op.imm, val)

  of IrOpKind.irMacFast:
    let s1 = signExtend24(regs[int(op.src1)])
    let s2 = signExtend24(regs[int(op.src2)])
    var prod = (int64(s1) * int64(s2)) shl 1
    if op.isNeg: prod = -prod
    var acc = if op.dst == RegId.regB: accB else: accA
    acc = signExtend56(cast[uint64](acc + prod))
    if op.dst == RegId.regB: accB = acc else: accA = acc
    if acc == 0:
      sr = (sr or SR_Z) and (not SR_N)
    elif acc < 0:
      sr = (sr or SR_N) and (not SR_Z)
    else:
      sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irMpyFast:
    let s1 = signExtend24(regs[int(op.src1)])
    let s2 = signExtend24(regs[int(op.src2)])
    var prod = (int64(s1) * int64(s2)) shl 1
    if op.isNeg: prod = -prod
    let acc = signExtend56(cast[uint64](prod))
    if op.dst == RegId.regB: accB = acc else: accA = acc
    if acc == 0:
      sr = (sr or SR_Z) and (not SR_N)
    elif acc < 0:
      sr = (sr or SR_N) and (not SR_Z)
    else:
      sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irAddFast:
    let addVal = if op.src1 <= RegId.regY1:
      cast[int64](cast[int32](regs[int(op.src1)] shl 8)) shl 16
    elif op.src1 == RegId.regA:
      accA
    elif op.src1 == RegId.regB:
      accB
    else:
      int64(signExtend24(readRegFast(op.src1))) shl 24
    var acc = if op.dst == RegId.regB: accB else: accA
    acc = signExtend56(cast[uint64](acc + addVal))
    if op.dst == RegId.regB: accB = acc else: accA = acc
    if acc == 0:
      sr = (sr or SR_Z) and (not SR_N)
    elif acc < 0:
      sr = (sr or SR_N) and (not SR_Z)
    else:
      sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irSubFast:
    let subVal = if op.src1 <= RegId.regY1:
      cast[int64](cast[int32](regs[int(op.src1)] shl 8)) shl 16
    elif op.src1 == RegId.regA:
      accA
    elif op.src1 == RegId.regB:
      accB
    else:
      int64(signExtend24(readRegFast(op.src1))) shl 24
    var acc = if op.dst == RegId.regB: accB else: accA
    acc = signExtend56(cast[uint64](acc - subVal))
    if op.dst == RegId.regB: accB = acc else: accA = acc
    if acc == 0:
      sr = (sr or SR_Z) and (not SR_N)
    elif acc < 0:
      sr = (sr or SR_N) and (not SR_Z)
    else:
      sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irCmpFast:
    let subVal = if op.src1 <= RegId.regY1:
      cast[int64](cast[int32](regs[int(op.src1)] shl 8)) shl 16
    elif op.src1 == RegId.regA:
      accA
    elif op.src1 == RegId.regB:
      accB
    else:
      int64(signExtend24(readRegFast(op.src1))) shl 24
    let acc = if op.dst == RegId.regB: accB else: accA
    let diff = signExtend56(cast[uint64](acc - subVal))
    if diff == 0:
      sr = (sr or SR_Z) and (not SR_N)
    elif diff < 0:
      sr = (sr or SR_N) and (not SR_Z)
    else:
      sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irClrFast:
    if op.dst == RegId.regB: accB = 0 else: accA = 0
    sr = (sr or SR_Z) and (not SR_N)

  of IrOpKind.irTfrFast:
    let acc = if op.src1 == RegId.regA: accA else: accB
    if op.dst == RegId.regB: accB = acc else: accA = acc
    if acc == 0:
      sr = (sr or SR_Z) and (not SR_N)
    elif acc < 0:
      sr = (sr or SR_N) and (not SR_Z)
    else:
      sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irLoadImm:
    if op.dst == RegId.regA:
      accA = cast[int64](cast[int32](op.imm shl 8)) shl 16
    elif op.dst <= RegId.regY1:
      regs[int(op.dst)] = op.imm and 0x00FFFFFF'u32
    elif op.dst == RegId.regB:
      accB = cast[int64](cast[int32](op.imm shl 8)) shl 16
    else:
      setRegFast(op.dst, op.imm)

  of IrOpKind.irLoadReg:
    let v = readRegFast(op.src1)
    if op.dst == RegId.regA:
      accA = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
    elif op.dst == RegId.regB:
      accB = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
    else:
      setRegFast(op.dst, v)

  of IrOpKind.irStoreReg:
    let v = readRegFast(op.src1)
    if op.dst == RegId.regA:
      accA = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
    elif op.dst == RegId.regB:
      accB = signExtend56(cast[uint64](int64(signExtend24(v)) shl 24))
    else:
      setRegFast(op.dst, v)

  of IrOpKind.irLoadMem:
    let targetAddr = if op.addrMode == AddrMode.amAbsolute:
      op.imm
    else:
      regs[int(RegId.regR0) + int(op.rNum)]
    var val: uint32
    if likely(targetAddr < xLen):
      val = if op.space == MemSpace.memX: xRamPtr[targetAddr] else: yRamPtr[targetAddr]
    elif targetAddr >= 0xFFFF80'u32:
      let space = if op.space == MemSpace.memX: Dsp56300Space.SpaceX else: Dsp56300Space.SpaceY
      state.core.sr = sr
      val = state.mem.readMem(state.core, space, targetAddr)
    if op.dst == RegId.regA:
      accA = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
    elif op.dst == RegId.regB:
      accB = signExtend56(cast[uint64](int64(signExtend24(val)) shl 24))
    else:
      setRegFast(op.dst, val)

  of IrOpKind.irStoreMem:
    let targetAddr = if op.addrMode == AddrMode.amAbsolute:
      op.imm
    else:
      regs[int(RegId.regR0) + int(op.rNum)]
    let val = readRegFast(op.src1)
    if likely(targetAddr < xLen):
      let maskedVal = val and 0x00FFFFFF'u32
      if op.space == MemSpace.memX:
        xRamPtr[targetAddr] = maskedVal
      else:
        yRamPtr[targetAddr] = maskedVal
    elif targetAddr >= 0xFFFF80'u32:
      let space = if op.space == MemSpace.memX: Dsp56300Space.SpaceX else: Dsp56300Space.SpaceY
      state.core.sr = sr
      state.mem.writeMem(state.core, space, targetAddr, val)

  of IrOpKind.irAguUpdate:
    let rIdx = int(RegId.regR0) + int(op.rNum)
    let delta: int32 = case op.addrMode
    of AddrMode.amPostInc: 1
    of AddrMode.amPostDec: -1
    of AddrMode.amPostIncN: int32(regs[int(RegId.regN0) + int(op.rNum)])
    of AddrMode.amPostDecN: -int32(regs[int(RegId.regN0) + int(op.rNum)])
    else: 0
    if delta != 0:
      let mVal = regs[int(RegId.regM0) + int(op.rNum)]
      if likely((mVal and 0xFFFF'u32) == 0xFFFF'u32):
        regs[rIdx] = (uint32(int32(regs[rIdx]) + delta)) and 0x00FFFFFF'u32
      else:
        regs[rIdx] = agu.updateAddress(regs[rIdx], delta, mVal)

  of IrOpKind.irAluOp:
    var acc = if op.dst == RegId.regB: accB else: accA
    case op.aluOp
    of AluOp.opMpy, AluOp.opMpyr:
      let s1 = signExtend24(readRegFast(op.src1))
      let s2 = signExtend24(readRegFast(op.src2))
      var prod = (int64(s1) * int64(s2)) shl 1
      if op.isNeg: prod = -prod
      acc = signExtend56(cast[uint64](prod))
    of AluOp.opMac, AluOp.opMacr:
      let s1 = signExtend24(readRegFast(op.src1))
      let s2 = signExtend24(readRegFast(op.src2))
      var prod = (int64(s1) * int64(s2)) shl 1
      if op.isNeg: prod = -prod
      acc = signExtend56(cast[uint64](acc + prod))
    of AluOp.opAdd:
      let addVal = if op.src1 == RegId.regA:
        accA
      elif op.src1 == RegId.regB:
        accB
      else:
        int64(signExtend24(readRegFast(op.src1))) shl 24
      acc = signExtend56(cast[uint64](acc + addVal))
    of AluOp.opSub:
      let subVal = if op.src1 == RegId.regA:
        accA
      elif op.src1 == RegId.regB:
        accB
      else:
        int64(signExtend24(readRegFast(op.src1))) shl 24
      acc = signExtend56(cast[uint64](acc - subVal))
    of AluOp.opClr:
      acc = 0
    of AluOp.opTfr:
      acc = if op.src1 == RegId.regA: accA else: accB
    of AluOp.opTst:
      discard
    of AluOp.opNeg:
      acc = signExtend56(cast[uint64](-acc))
    of AluOp.opAbs:
      if acc < 0: acc = signExtend56(cast[uint64](-acc))
    of AluOp.opAsl:
      let cOut = ((cast[uint64](acc) and (1'u64 shl 47)) != 0) or ((cast[uint64](acc) and (1'u64 shl 55)) != 0)
      acc = signExtend56(cast[uint64](acc shl 1))
      if cOut:
        sr = sr or SR_C
      else:
        sr = sr and (not SR_C)
    of AluOp.opAsr:
      acc = signExtend56(cast[uint64](acc shr 1))
    of AluOp.opLsr:
      acc = signExtend56((cast[uint64](acc) and 0x00FFFFFFFFFFFFFF'u64) shr 1)
    of AluOp.opCmp:
      let subVal = if op.src1 == RegId.regA:
        accA
      elif op.src1 == RegId.regB:
        accB
      else:
        int64(signExtend24(readRegFast(op.src1))) shl 24
      let diff = signExtend56(cast[uint64](acc - subVal))
      if diff == 0:
        sr = sr or SR_Z
      else:
        sr = sr and (not SR_Z)
      if diff < 0:
        sr = sr or SR_N
      else:
        sr = sr and (not SR_N)
    of AluOp.opAnd:
      let s1 = signExtend24(readRegFast(op.src1))
      acc = acc and (int64(s1) shl 24)
    of AluOp.opOr:
      let s1 = signExtend24(readRegFast(op.src1))
      acc = acc or (int64(s1) shl 24)
    of AluOp.opEor:
      let s1 = signExtend24(readRegFast(op.src1))
      acc = acc xor (int64(s1) shl 24)
    of AluOp.opNot:
      acc = not acc
    else: discard

    if op.aluOp != AluOp.opCmp:
      if op.dst == RegId.regB:
        accB = acc
      else:
        accA = acc
      if acc == 0:
        sr = (sr or SR_Z) and (not SR_N)
      elif acc < 0:
        sr = (sr or SR_N) and (not SR_Z)
      else:
        sr = sr and (not (SR_Z or SR_N))

  of IrOpKind.irBranch, IrOpKind.irBranchCond:
    discard

  of IrOpKind.irCall:
    state.core.stackPush(pc + 1, sr)
    pc = op.imm
    cycles += 2
    syncAndReturn(true)

  of IrOpKind.irReturn:
    var newPc, dummySr: uint32
    state.core.stackPop(newPc, dummySr)
    pc = newPc
    cycles += 2
    syncAndReturn(true)

  of IrOpKind.irReturnInt:
    var newPc, newSr: uint32
    state.core.stackPop(newPc, newSr)
    pc = newPc
    sr = newSr
    cycles += 2
    syncAndReturn(true)

  of IrOpKind.irLoopDo:
    lc = op.imm
    la = op.pAddr
    sr = sr or SR_LF
    cycles += 2

  of IrOpKind.irLoopEndDo:
    sr = sr and (not SR_LF)
    cycles += 1

  of IrOpKind.irLoopBrkCc:
    if evalCondition(op.cond, sr):
      sr = sr and (not SR_LF)
      pc = la + 1
      cycles += 2
      syncAndReturn(true)

  of IrOpKind.irLoopRep:
    state.core.repCount = op.imm
    state.core.repActive = true
    cycles += 1

  of IrOpKind.irLoopDoForever:
    la = op.pAddr
    sr = sr or SR_LF or SR_FV
    cycles += 2

  of IrOpKind.irHalt:
    state.core.halted = true
    cycles += 1
    syncAndReturn(true)

  syncAndReturn(false)


proc runUntilTx*(state: var DspState,
                 blockCache: ptr array[65536, ref IrBasicBlock],
                 txWritten: ptr bool,
                 maxCycles: uint32): uint32 =
  ## High-performance multi-block execution loop.
  ## Keeps 56-bit accumulators and registers in native locals until
  ## ESAI TX is written (`txWritten[] == true`), PC wraps to 0, or maxCycles is reached.
  if state.core.halted:
    return 0
  if state.core.pc == 0 and state.mem.pRam[0] == 0'u32:
    return 0

  var cycles = 0'u32
  var accA: int64 = state.getAccA()
  var accB: int64 = state.getAccB()
  var pc: uint32 = state.core.pc
  var sr: uint32 = state.core.sr
  var la: uint32 = state.core.la
  var lc: uint32 = state.core.lc
  var regs: array[52, uint32]
  regs[int(RegId.regX0)] = state.core.x0
  regs[int(RegId.regX1)] = state.core.x1
  regs[int(RegId.regY0)] = state.core.y0
  regs[int(RegId.regY1)] = state.core.y1
  for idx in 0..7:
    regs[int(RegId.regR0) + idx] = state.core.r[idx]
    regs[int(RegId.regN0) + idx] = state.core.n[idx]
    regs[int(RegId.regM0) + idx] = state.core.m[idx]

  let xRamPtr = if state.mem.xRam.len > 0: cast[ptr UncheckedArray[uint32]](addr state.mem.xRam[0]) else: nil
  let yRamPtr = if state.mem.yRam.len > 0: cast[ptr UncheckedArray[uint32]](addr state.mem.yRam[0]) else: nil
  let xLen = uint32(state.mem.xRam.len)

  template updateCcrZN(acc: int64) =
    let uAcc = cast[uint64](acc)
    let zBit = (uint32(uAcc == 0)) shl 2
    let nBit = uint32((uAcc shr 60) and 8'u64)
    sr = (sr and (not 12'u32)) or zBit or nBit

  template limitAccFast(val: int64): uint32 =
    let u = cast[uint64](val)
    let sMode = (sr shr 10) and 0x03'u32
    if likely(sMode == 0):
      let top9 = (u shr 47) and 0x1FF'u64
      if likely(top9 == 0 or top9 == 0x1FF'u64):
        if ((u xor (u shl 1)) and (1'u64 shl 46)) != 0:
          sr = sr or SR_S
        uint32((u shr 24) and 0x00FFFFFF'u64)
      else:
        # Limiter saturation:
        sr = sr or SR_L or SR_S
        if (u and (1'u64 shl 55)) == 0: 0x007FFFFF'u32 else: 0x00800000'u32
    elif sMode == 1:
      if ((u xor (u shl 1)) and (1'u64 shl 47)) != 0: sr = sr or SR_S
      let top8 = (u shr 48) and 0xFF'u64
      if likely(top8 == 0 or top8 == 0xFF'u64):
        uint32((u shr 25) and 0x00FFFFFF'u64)
      else:
        sr = sr or SR_L
        if (u and (1'u64 shl 55)) == 0: 0x007FFFFF'u32 else: 0x00800000'u32
    elif sMode == 2:
      if ((u xor (u shl 1)) and (1'u64 shl 45)) != 0: sr = sr or SR_S
      let top10 = (u shr 46) and 0x3FF'u64
      if likely(top10 == 0 or top10 == 0x3FF'u64):
        uint32((u shr 23) and 0x00FFFFFF'u64)
      else:
        sr = sr or SR_L
        if (u and (1'u64 shl 55)) == 0: 0x007FFFFF'u32 else: 0x00800000'u32
    else:
      uint32((u shr 24) and 0x00FFFFFF'u64)

  var blk: ptr IrBasicBlock = nil

  while cycles < maxCycles and not state.core.halted:
    if blk == nil:
      let idx = int(pc and 0xFFFF'u32)
      blk = cast[ptr IrBasicBlock](blockCache[][idx])
      if unlikely(blk == nil):
        if idx >= state.mem.pRam.len or state.mem.pRam[idx] == 0'u32:
          break
        var rBlk: ref IrBasicBlock
        new(rBlk)
        rBlk[] = liftBasicBlock(state, pc, maxWords = 1024)
        rBlk.fastOpsArr = if rBlk.fastOps.len > 0: cast[ptr UncheckedArray[FastOp]](addr rBlk.fastOps[0]) else: nil
        blockCache[][idx] = rBlk
        blk = cast[ptr IrBasicBlock](rBlk)


    let numFastOps = blk.numFastOps
    let fastOpsPtr = blk.fastOpsArr
    let hadPeriphWrite = blk.writesPeriph

    var branched = false

    template execFastOp(fop: ptr FastOp) =
      case fop.kind
        of fopNop:
          discard

        of fopLoadXAbsA:
          accA = cast[int64](cast[int32](xRamPtr[fop.imm] shl 8)) shl 16

        of fopLoadYAbsA:
          accA = cast[int64](cast[int32](yRamPtr[fop.imm] shl 8)) shl 16

        of fopLoadXAbsB:
          accB = cast[int64](cast[int32](xRamPtr[fop.imm] shl 8)) shl 16

        of fopLoadYAbsB:
          accB = cast[int64](cast[int32](yRamPtr[fop.imm] shl 8)) shl 16

        of fopLoadXAbsReg:
          regs[fop.dst] = xRamPtr[fop.imm]

        of fopLoadYAbsReg:
          regs[fop.dst] = yRamPtr[fop.imm]

        of fopStoreXAbsA1:
          xRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopStoreYAbsA1:
          yRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopStoreXAbsA:
          xRamPtr[fop.imm] = limitAccFast(accA)

        of fopStoreYAbsA:
          yRamPtr[fop.imm] = limitAccFast(accA)

        of fopStoreXAbsReg:
          xRamPtr[fop.imm] = regs[fop.src1]

        of fopStoreYAbsReg:
          yRamPtr[fop.imm] = regs[fop.src1]

        of fopLoadImmA:
          accA = cast[int64](cast[int32](fop.imm shl 8)) shl 16

        of fopLoadImmB:
          accB = cast[int64](cast[int32](fop.imm shl 8)) shl 16

        of fopLoadImmReg:
          regs[fop.dst] = fop.imm and 0x00FFFFFF'u32

        of fopLoadRegReg:
          regs[fop.dst] = regs[fop.src1]

        of fopLoadRegA:
          accA = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16

        of fopLoadRegB:
          accB = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16

        of fopStoreRegA1:
          regs[fop.dst] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopAddReg:
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))
          updateCcrZN(accA)

        of fopSubReg:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA - subVal))
          updateCcrZN(accA)

        of fopAddRegB:
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accB = signExtend56(cast[uint64](accB + addVal))
          updateCcrZN(accB)

        of fopSubRegB:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accB = signExtend56(cast[uint64](accB - subVal))
          updateCcrZN(accB)

        of fopAddAcc:
          let addVal = if fop.src1 == uint8(RegId.regA): accA else: accB
          accA = signExtend56(cast[uint64](accA + addVal))
          updateCcrZN(accA)

        of fopSubAcc:
          let subVal = if fop.src1 == uint8(RegId.regA): accA else: accB
          accA = signExtend56(cast[uint64](accA - subVal))
          updateCcrZN(accA)

        of fopCmpReg:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          let diff = accA - subVal
          updateCcrZN(diff)

        of fopCmpZeroA:
          updateCcrZN(accA)

        of fopCmpImmA:
          let subVal = cast[int64](cast[int32](fop.imm shl 8)) shl 16
          let diff = accA - subVal
          updateCcrZN(diff)

        of fopAddRegNoCcr:
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))

        of fopSubRegNoCcr:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA - subVal))

        of fopMpyRegNoCcr:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1

        of fopMacRegNoCcr:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          let prod = (int64(s1) * int64(s2)) shl 1
          accA = signExtend56(cast[uint64](accA + prod))

        of fopMpyReg:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1
          updateCcrZN(accA)

        of fopMpyNegReg:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = -((int64(s1) * int64(s2)) shl 1)
          updateCcrZN(accA)

        of fopMacReg:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          let prod = (int64(s1) * int64(s2)) shl 1
          accA = signExtend56(cast[uint64](accA + prod))
          updateCcrZN(accA)

        of fopMacNegReg:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          let prod = -((int64(s1) * int64(s2)) shl 1)
          accA = signExtend56(cast[uint64](accA + prod))
          updateCcrZN(accA)

        of fopMpyRegB:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accB = (int64(s1) * int64(s2)) shl 1
          updateCcrZN(accB)

        of fopMacRegB:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          let prod = (int64(s1) * int64(s2)) shl 1
          accB = signExtend56(cast[uint64](accB + prod))
          updateCcrZN(accB)

        of fopClrA:
          accA = 0
          sr = (sr or SR_Z) and (not SR_N)

        of fopClrB:
          accB = 0
          sr = (sr or SR_Z) and (not SR_N)

        of fopTfrA:
          accA = accB
          updateCcrZN(accA)

        of fopTfrB:
          accB = accA
          updateCcrZN(accB)

        of fopAslA:
          let cOut = ((cast[uint64](accA) and (1'u64 shl 47)) != 0) or ((cast[uint64](accA) and (1'u64 shl 55)) != 0)
          accA = signExtend56(cast[uint64](accA shl 1))
          if cOut: sr = sr or SR_C else: sr = sr and (not SR_C)
          updateCcrZN(accA)

        of fopAsrA:
          accA = signExtend56(cast[uint64](accA shr 1))
          updateCcrZN(accA)

        of fopAguPostInc:
          let rIdx = int(RegId.regR0) + int(fop.src1)
          let mVal = regs[int(RegId.regM0) + int(fop.src1)]
          if likely((mVal and 0xFFFF'u32) == 0xFFFF'u32):
            regs[rIdx] = (regs[rIdx] + 1) and 0x00FFFFFF'u32
          else:
            regs[rIdx] = agu.updateAddress(regs[rIdx], 1, mVal)

        of fopAguPostDec:
          let rIdx = int(RegId.regR0) + int(fop.src1)
          let mVal = regs[int(RegId.regM0) + int(fop.src1)]
          if likely((mVal and 0xFFFF'u32) == 0xFFFF'u32):
            regs[rIdx] = (regs[rIdx] - 1) and 0x00FFFFFF'u32
          else:
            regs[rIdx] = agu.updateAddress(regs[rIdx], -1, mVal)

        of fopAguPostIncN:
          let rIdx = int(RegId.regR0) + int(fop.src1)
          let delta = int32(regs[int(RegId.regN0) + int(fop.src1)])
          let mVal = regs[int(RegId.regM0) + int(fop.src1)]
          if likely((mVal and 0xFFFF'u32) == 0xFFFF'u32):
            regs[rIdx] = (uint32(int32(regs[rIdx]) + delta)) and 0x00FFFFFF'u32
          else:
            regs[rIdx] = agu.updateAddress(regs[rIdx], delta, mVal)

        of fopAguPostDecN:
          let rIdx = int(RegId.regR0) + int(fop.src1)
          let delta = -int32(regs[int(RegId.regN0) + int(fop.src1)])
          let mVal = regs[int(RegId.regM0) + int(fop.src1)]
          if likely((mVal and 0xFFFF'u32) == 0xFFFF'u32):
            regs[rIdx] = (uint32(int32(regs[rIdx]) + delta)) and 0x00FFFFFF'u32
          else:
            regs[rIdx] = agu.updateAddress(regs[rIdx], delta, mVal)

        of fopCopyYtoX:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = yRamPtr[src]
          accA = cast[int64](cast[int32](val shl 8)) shl 16
          xRamPtr[fop.imm] = val

        of fopCopyXtoY:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = xRamPtr[src]
          accA = cast[int64](cast[int32](val shl 8)) shl 16
          yRamPtr[fop.imm] = val

        of fopStoreImmY:
          let dst = cast[ptr uint16](addr fop.src1)[]
          accA = cast[int64](cast[int32](fop.imm shl 8)) shl 16
          yRamPtr[dst] = fop.imm and 0x00FFFFFF'u32

        of fopStoreImmX:
          let dst = cast[ptr uint16](addr fop.src1)[]
          accA = cast[int64](cast[int32](fop.imm shl 8)) shl 16
          xRamPtr[dst] = fop.imm and 0x00FFFFFF'u32

        of fopLoadXAbsCmpImm:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = xRamPtr[src]
          let sVal = cast[int32](val shl 8)
          let sImm = cast[int32](fop.imm shl 8)
          accA = cast[int64](sVal) shl 16
          let zBit = (uint32(sVal == sImm)) shl 2
          let nBit = (uint32(sVal < sImm)) shl 3
          sr = (sr and (not 12'u32)) or zBit or nBit

        of fopLoadYAbsCmpImm:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = yRamPtr[src]
          let sVal = cast[int32](val shl 8)
          let sImm = cast[int32](fop.imm shl 8)
          accA = cast[int64](sVal) shl 16
          let zBit = (uint32(sVal == sImm)) shl 2
          let nBit = (uint32(sVal < sImm)) shl 3
          sr = (sr and (not 12'u32)) or zBit or nBit

        of fopMpyStoreY:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1
          yRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopMpyStoreX:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1
          xRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopMacStoreY:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          let prod = (int64(s1) * int64(s2)) shl 1
          accA = signExtend56(cast[uint64](accA + prod))
          yRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopMacStoreX:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          let prod = (int64(s1) * int64(s2)) shl 1
          accA = signExtend56(cast[uint64](accA + prod))
          xRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopAddStoreY:
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))
          yRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopAddStoreX:
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))
          xRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopSubStoreY:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA - subVal))
          yRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopSubStoreX:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA - subVal))
          xRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopMpyStoreReg:
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1
          regs[fop.dst] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopLoadYAbsAddReg:
          accA = cast[int64](cast[int32](yRamPtr[fop.imm] shl 8)) shl 16
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))

        of fopLoadXAbsAddReg:
          accA = cast[int64](cast[int32](xRamPtr[fop.imm] shl 8)) shl 16
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))

        of fopCopyYtoY:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = yRamPtr[src]
          accA = cast[int64](cast[int32](val shl 8)) shl 16
          if fop.dst != 11:
            regs[fop.dst] = val
          yRamPtr[fop.imm] = val

        of fopCopyXtoX:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = xRamPtr[src]
          accA = cast[int64](cast[int32](val shl 8)) shl 16
          if fop.dst != 11:
            regs[fop.dst] = val
          xRamPtr[fop.imm] = val

        of fopLoadAddYReg:
          let val = yRamPtr[fop.imm]
          regs[fop.dst] = val
          let addVal = cast[int64](cast[int32](val shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))

        of fopLoadAddXReg:
          let val = xRamPtr[fop.imm]
          regs[fop.dst] = val
          let addVal = cast[int64](cast[int32](val shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))

        of fopLoadDualXY:
          regs[fop.src1] = xRamPtr[fop.imm and 0xFFFF'u32]
          regs[fop.src2] = yRamPtr[fop.imm shr 16]

        of fopLoadDualXX:
          regs[fop.src1] = xRamPtr[fop.imm and 0xFFFF'u32]
          regs[fop.src2] = xRamPtr[fop.imm shr 16]

        of fopLoadDualYY:
          regs[fop.src1] = yRamPtr[fop.imm and 0xFFFF'u32]
          regs[fop.src2] = yRamPtr[fop.imm shr 16]

        of fopStoreRegLoadY:
          regs[fop.dst] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
          regs[fop.src1] = yRamPtr[fop.imm]

        of fopStoreRegLoadX:
          regs[fop.dst] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
          regs[fop.src1] = xRamPtr[fop.imm]

        of fopLoadAddStoreY:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = yRamPtr[src]
          regs[fop.dst] = val
          let addVal = cast[int64](cast[int32](val shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))
          yRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopLoadAddStoreX:
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = yRamPtr[src]
          regs[fop.dst] = val
          let addVal = cast[int64](cast[int32](val shl 8)) shl 16
          accA = signExtend56(cast[uint64](accA + addVal))
          xRamPtr[fop.imm] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopLoadYMpyStoreY:
          let rVal = yRamPtr[fop.imm and 0xFFFF'u32]
          regs[fop.dst] = rVal
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1
          yRamPtr[fop.imm shr 16] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopLoadXMpyStoreY:
          let rVal = xRamPtr[fop.imm and 0xFFFF'u32]
          regs[fop.dst] = rVal
          let s1 = cast[int32](regs[fop.src1] shl 8) shr 8
          let s2 = cast[int32](regs[fop.src2] shl 8) shr 8
          accA = (int64(s1) * int64(s2)) shl 1
          yRamPtr[fop.imm shr 16] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)

        of fopStoreRegLoadAddY:
          regs[fop.dst] = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
          let val = yRamPtr[fop.imm]
          let addVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          accA = signExtend56(cast[uint64]((cast[int64](cast[int32](val shl 8)) shl 16) + addVal))

        of fopCopyMultiYtoX:
          let src = cast[ptr uint16](addr fop.src1)[]
          let dst = fop.imm
          let count = int(fop.dst)
          copyMem(addr xRamPtr[dst], addr yRamPtr[src], count * sizeof(uint32))
          accA = cast[int64](cast[int32](yRamPtr[src + uint32(count - 1)] shl 8)) shl 16

        of fopCopyMultiXtoY:
          let src = cast[ptr uint16](addr fop.src1)[]
          let dst = fop.imm
          let count = int(fop.dst)
          copyMem(addr yRamPtr[dst], addr xRamPtr[src], count * sizeof(uint32))
          accA = cast[int64](cast[int32](xRamPtr[src + uint32(count - 1)] shl 8)) shl 16

        of fopStoreMultiImmY:
          let dst = cast[ptr uint16](addr fop.src1)[]
          let count = int(fop.dst)
          let v = fop.imm and 0x00FFFFFF'u32
          accA = cast[int64](cast[int32](fop.imm shl 8)) shl 16
          for k in 0 ..< count:
            yRamPtr[dst + uint32(k)] = v

        of fopStoreMultiImmX:
          let dst = cast[ptr uint16](addr fop.src1)[]
          let count = int(fop.dst)
          let v = fop.imm and 0x00FFFFFF'u32
          accA = cast[int64](cast[int32](fop.imm shl 8)) shl 16
          for k in 0 ..< count:
            xRamPtr[dst + uint32(k)] = v

        of fopNegA:
          accA = signExtend56(cast[uint64](-accA))
          updateCcrZN(accA)

        of fopLoadXAbsTstA:
          accA = cast[int64](cast[int32](xRamPtr[fop.imm] shl 8)) shl 16
          updateCcrZN(accA)

        of fopLoadYAbsTstA:
          accA = cast[int64](cast[int32](yRamPtr[fop.imm] shl 8)) shl 16
          updateCcrZN(accA)

        of fopTstA:
          updateCcrZN(accA)

        of fopAndRegA:
          let s1 = signExtend24(regs[fop.src1])
          accA = accA and (int64(s1) shl 24)
          updateCcrZN(accA)

        of fopSexA1:
          let a1 = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
          accA = cast[int64](cast[int32](a1 shl 8)) shl 16
          updateCcrZN(accA)

        of fopLoadPeriphX:
          let val = state.mem.readMem(state.core, SpaceX, fop.imm)
          accA = cast[int64](cast[int32](val shl 8)) shl 16
          updateCcrZN(accA)

        of fopStorePeriphXA:
          let val = limitAccFast(accA)
          state.mem.writeMem(state.core, SpaceX, fop.imm, val)

        of fopStorePeriphXA1:
          let val = uint32((cast[uint64](accA) shr 24) and 0x00FFFFFF'u64)
          state.mem.writeMem(state.core, SpaceX, fop.imm, val)

        of fopCmpRegB:
          let subVal = cast[int64](cast[int32](regs[fop.src1] shl 8)) shl 16
          let diff = accB - subVal
          updateCcrZN(diff)

        of fopStoreRegA:
          regs[fop.dst] = limitAccFast(accA)

        of fopStoreRegB1:
          regs[fop.dst] = uint32((cast[uint64](accB) shr 24) and 0x00FFFFFF'u64)

        of fopStoreYAbsB:
          yRamPtr[fop.imm] = limitAccFast(accB)

        of fopTstB:
          updateCcrZN(accB)

        of fopOrRegA:
          let s1 = signExtend24(regs[fop.src1])
          accA = accA or (int64(s1) shl 24)
          updateCcrZN(accA)

        of fopFallback:
          let mop = addr blk.ops[fop.imm]
          let uA = cast[uint64](accA)
          state.core.a2 = uint8((uA shr 48) and 0xFF'u64)
          state.core.a1 = uint32((uA shr 24) and 0x00FFFFFF'u64)
          state.core.a0 = uint32(uA and 0x00FFFFFF'u64)
          let uB = cast[uint64](accB)
          state.core.b2 = uint8((uB shr 48) and 0xFF'u64)
          state.core.b1 = uint32((uB shr 24) and 0x00FFFFFF'u64)
          state.core.b0 = uint32(uB and 0x00FFFFFF'u64)
          state.core.pc = pc
          state.core.sr = sr
          state.core.la = la
          state.core.lc = lc
          state.core.x0 = regs[int(RegId.regX0)]
          state.core.x1 = regs[int(RegId.regX1)]
          state.core.y0 = regs[int(RegId.regY0)]
          state.core.y1 = regs[int(RegId.regY1)]
          for idx in 0..7:
            state.core.r[idx] = regs[int(RegId.regR0) + idx]
            state.core.n[idx] = regs[int(RegId.regN0) + idx]
            state.core.m[idx] = regs[int(RegId.regM0) + idx]

          let res = execFallbackOp(state, mop)
          cycles += res.cycles

          accA = state.getAccA()
          accB = state.getAccB()
          pc = state.core.pc
          sr = state.core.sr
          la = state.core.la
          lc = state.core.lc
          regs[int(RegId.regX0)] = state.core.x0
          regs[int(RegId.regX1)] = state.core.x1
          regs[int(RegId.regY0)] = state.core.y0
          regs[int(RegId.regY1)] = state.core.y1
          for idx in 0..7:
            regs[int(RegId.regR0) + idx] = state.core.r[idx]
            regs[int(RegId.regN0) + idx] = state.core.n[idx]
            regs[int(RegId.regM0) + idx] = state.core.m[idx]

          if res.branched:
            branched = true
            break


    cycles += uint32(numFastOps)
    if likely(not blk.isLoopBlock):
      if numFastOps == 1:
        let fop = addr fastOpsPtr[0]
        if likely(fop.kind == fopLoadYAbsCmpImm):
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = yRamPtr[src]
          let sVal = cast[int32](val shl 8)
          let sImm = cast[int32](fop.imm shl 8)
          accA = cast[int64](sVal) shl 16
          let zBit = (uint32(sVal == sImm)) shl 2
          let nBit = (uint32(sVal < sImm)) shl 3
          sr = (sr and (not 12'u32)) or zBit or nBit
        elif likely(fop.kind == fopLoadXAbsCmpImm):
          let src = cast[ptr uint16](addr fop.src1)[]
          let val = xRamPtr[src]
          let sVal = cast[int32](val shl 8)
          let sImm = cast[int32](fop.imm shl 8)
          accA = cast[int64](sVal) shl 16
          let zBit = (uint32(sVal == sImm)) shl 2
          let nBit = (uint32(sVal < sImm)) shl 3
          sr = (sr and (not 12'u32)) or zBit or nBit
        elif fop.kind == fopLoadYAbsTstA:
          let val = yRamPtr[fop.imm]
          let sVal = cast[int32](val shl 8)
          accA = cast[int64](sVal) shl 16
          let zBit = (uint32(sVal == 0)) shl 2
          let nBit = (uint32(sVal < 0)) shl 3
          sr = (sr and (not 12'u32)) or zBit or nBit
        elif fop.kind == fopCmpImmA:
          let subVal = cast[int64](cast[int32](fop.imm shl 8)) shl 16
          let diff = accA - subVal
          updateCcrZN(diff)
        else:
          execFastOp(fop)

      elif numFastOps == 2:
        execFastOp(addr fastOpsPtr[0])
        execFastOp(addr fastOpsPtr[1])
      else:
        for opIdx in 0 ..< numFastOps:
          execFastOp(addr fastOpsPtr[opIdx])

    else:
      cycles += uint32(numFastOps) * (blk.loopIterations - 1)
      for iter in 0 ..< blk.loopIterations:
        for opIdx in 0 ..< numFastOps:
          execFastOp(addr fastOpsPtr[opIdx])
        if branched: break

    if likely(blk.hasCondBranch):
      cycles += 2
      let condMet = evalCondition(blk.branchCond, sr)
      var nextB = if condMet: cast[ptr IrBasicBlock](blk.branchBlk) else: cast[ptr IrBasicBlock](blk.nextBlk)
      if unlikely(nextB == nil):
        let nextTarget = if condMet: blk.branchTargetPc else: blk.endPc
        pc = nextTarget
        if nextTarget < 65536:
          nextB = cast[ptr IrBasicBlock](blockCache[][int(nextTarget)])
          if condMet: blk.branchBlk = cast[pointer](nextB)
          else: blk.nextBlk = cast[pointer](nextB)
      else:
        pc = nextB.startPc
      blk = nextB
    elif blk.hasBranch:
      cycles += 2
      pc = blk.branchTargetPc
      if unlikely(blk.branchBlk == nil and blk.branchTargetPc < 65536):
        blk.branchBlk = cast[pointer](blockCache[][int(blk.branchTargetPc)])
      blk = cast[ptr IrBasicBlock](blk.branchBlk)
    elif blk.isLoopBlock:
      pc = blk.loopEndPc + 1
      lc = 0
      sr = sr and (not SR_LF)
      if blk.nextBlk == nil and pc < 65536:
        blk.nextBlk = cast[pointer](blockCache[][int(pc)])
      blk = cast[ptr IrBasicBlock](blk.nextBlk)
    elif not branched:
      pc = blk.endPc
      if blk.nextBlk == nil and blk.endPc < 65536:
        blk.nextBlk = cast[pointer](blockCache[][int(blk.endPc)])
      blk = cast[ptr IrBasicBlock](blk.nextBlk)
    else:
      blk = nil
      branched = false

    if unlikely(hadPeriphWrite):
      if txWritten != nil and txWritten[]:
        break
    if unlikely(pc == 0 and cycles > 0):
      break


  # Sync local registers back to DspState before returning
  let uA = cast[uint64](accA)
  state.core.a2 = uint8((uA shr 48) and 0xFF'u64)
  state.core.a1 = uint32((uA shr 24) and 0x00FFFFFF'u64)
  state.core.a0 = uint32(uA and 0x00FFFFFF'u64)

  let uB = cast[uint64](accB)
  state.core.b2 = uint8((uB shr 48) and 0xFF'u64)
  state.core.b1 = uint32((uB shr 24) and 0x00FFFFFF'u64)
  state.core.b0 = uint32(uB and 0x00FFFFFF'u64)

  state.core.pc = pc
  state.core.sr = sr
  state.core.la = la
  state.core.lc = lc
  state.core.x0 = regs[int(RegId.regX0)]
  state.core.x1 = regs[int(RegId.regX1)]
  state.core.y0 = regs[int(RegId.regY0)]
  state.core.y1 = regs[int(RegId.regY1)]
  for i in 0..7:
    state.core.r[i] = regs[int(RegId.regR0) + i]
    state.core.n[i] = regs[int(RegId.regN0) + i]
    state.core.m[i] = regs[int(RegId.regM0) + i]

  return cycles


