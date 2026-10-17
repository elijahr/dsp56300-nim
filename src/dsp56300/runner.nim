## Clean-room MIT Motorola DSP56300 Cold-Block IR Runner
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import dsp56300/[decode_types, state, memory, agu, alu, ir]

proc getReg24*(s: var DspState, reg: RegId): uint32 {.inline.} =
  if likely(reg >= RegId.regX0 and reg <= RegId.regY1):
    case reg
    of RegId.regX0: return s.x0
    of RegId.regX1: return s.x1
    of RegId.regY0: return s.y0
    of RegId.regY1: return s.y1
    else: discard
  case reg
  of RegId.regA0: s.a0
  of RegId.regA1: s.a1
  of RegId.regA2: uint32(s.a2)
  of RegId.regB0: s.b0
  of RegId.regB1: s.b1
  of RegId.regB2: uint32(s.b2)
  of RegId.regA: s.a1 # Limiting/MSP read
  of RegId.regB: s.b1
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
  if likely(reg >= RegId.regX0 and reg <= RegId.regY1):
    case reg
    of RegId.regX0: s.x0 = v
    of RegId.regX1: s.x1 = v
    of RegId.regY0: s.y0 = v
    of RegId.regY1: s.y1 = v
    else: discard
    return
  case reg
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
  let c = (sr and SR_C) != 0
  let v = (sr and SR_V) != 0
  let z = (sr and SR_Z) != 0
  let n = (sr and SR_N) != 0
  let u = (sr and SR_U) != 0
  let e = (sr and SR_E) != 0
  let l = (sr and SR_L) != 0

  case cc
  of ConditionCode.ccHS: not c
  of ConditionCode.ccLO: c
  of ConditionCode.ccEQ: z
  of ConditionCode.ccNE: not z
  of ConditionCode.ccPL: not n
  of ConditionCode.ccMI: n
  of ConditionCode.ccGE: (n == v)
  of ConditionCode.ccLT: (n != v)
  of ConditionCode.ccGT: (not z) and (n == v)
  of ConditionCode.ccLE: z or (n != v)
  of ConditionCode.ccEC: not e
  of ConditionCode.ccES: e
  of ConditionCode.ccLC: not l
  of ConditionCode.ccLS: l
  of ConditionCode.ccNN: not (z or (u and (not e)))
  of ConditionCode.ccNR: z or (u and (not e))

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
  let yLen = uint32(state.mem.yRam.len)

  let numOps = blk.ops.len
  if numOps == 0: return 0
  let opsPtr = cast[ptr UncheckedArray[MicroOp]](addr blk.ops[0])

  var accA = state.getAccA()
  var accB = state.getAccB()

  for iter in 0..<loopIterations:
    var opIdx = 0
    while opIdx < numOps:
      template op: untyped = opsPtr[opIdx]
      inc opIdx

      case op.kind
      of IrOpKind.irNop:
        cycles += 1

      of IrOpKind.irCheckGen:
        let addrIdx = int(op.pAddr)
        if addrIdx < state.pRamGen.len:
          if state.pRamGen[addrIdx] != op.expectedGen:
            # Stale block! Abort execution
            return cycles

      of IrOpKind.irLoadImm:
        setReg24(state, op.dst, op.imm)
        if op.dst == RegId.regA: accA = state.getAccA()
        elif op.dst == RegId.regB: accB = state.getAccB()

      of IrOpKind.irLoadReg:
        let v = getReg24(state, op.src1)
        setReg24(state, op.dst, v)
        if op.dst == RegId.regA: accA = state.getAccA()
        elif op.dst == RegId.regB: accB = state.getAccB()

      of IrOpKind.irStoreReg:
        let v = getReg24(state, op.src1)
        setReg24(state, op.dst, v)
        if op.dst == RegId.regA: accA = state.getAccA()
        elif op.dst == RegId.regB: accB = state.getAccB()

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
        setReg24(state, op.dst, val)
        if op.dst == RegId.regA: accA = state.getAccA()
        elif op.dst == RegId.regB: accB = state.getAccB()

      of IrOpKind.irStoreMem:
        let targetAddr = if op.addrMode == AddrMode.amAbsolute:
          op.imm
        else:
          state.r[op.rNum]
        let val = getReg24(state, op.src1)
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

      of IrOpKind.irAluOp:
        cycles += 1
        var acc = if op.dst == RegId.regB: accB else: accA

        case op.aluOp
        of AluOp.opMpy, AluOp.opMpyr:
          let s1 = signExtend24(getReg24(state, op.src1))
          let s2 = signExtend24(getReg24(state, op.src2))
          var prod = (int64(s1) * int64(s2)) shl 1
          if op.isNeg: prod = -prod
          acc = signExtend56(cast[uint64](prod))

        of AluOp.opMac, AluOp.opMacr:
          let s1 = signExtend24(getReg24(state, op.src1))
          let s2 = signExtend24(getReg24(state, op.src2))
          var prod = (int64(s1) * int64(s2)) shl 1
          if op.isNeg: prod = -prod
          acc = signExtend56(cast[uint64](acc + prod))

        of AluOp.opAdd:
          let addVal = if op.src1 == RegId.regA:
            accA
          elif op.src1 == RegId.regB:
            accB
          else:
            int64(signExtend24(getReg24(state, op.src1))) shl 24 # Left-align 24-bit input to MSP (bits 47..24)
          acc = signExtend56(cast[uint64](acc + addVal))

        of AluOp.opSub:
          let subVal = if op.src1 == RegId.regA:
            accA
          elif op.src1 == RegId.regB:
            accB
          else:
            int64(signExtend24(getReg24(state, op.src1))) shl 24
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
            int64(signExtend24(getReg24(state, op.src1))) shl 24
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
          let s1 = signExtend24(getReg24(state, op.src1))
          acc = acc and (int64(s1) shl 24)

        of AluOp.opOr:
          let s1 = signExtend24(getReg24(state, op.src1))
          acc = acc or (int64(s1) shl 24)

        of AluOp.opEor:
          let s1 = signExtend24(getReg24(state, op.src1))
          acc = acc xor (int64(s1) shl 24)

        of AluOp.opNot:
          acc = not acc

        else: discard

        if op.aluOp != AluOp.opCmp:
          if op.dst == RegId.regB:
            accB = acc
            let u = cast[uint64](acc)
            state.core.b2 = uint8((u shr 48) and 0xFF'u64)
            state.core.b1 = uint32((u shr 24) and 0x00FFFFFF'u64)
            state.core.b0 = uint32(u and 0x00FFFFFF'u64)
          else:
            accA = acc
            let u = cast[uint64](acc)
            state.core.a2 = uint8((u shr 48) and 0xFF'u64)
            state.core.a1 = uint32((u shr 24) and 0x00FFFFFF'u64)
            state.core.a0 = uint32(u and 0x00FFFFFF'u64)

          # Update condition code flags in SR (Z and N)
          if acc == 0:
            state.sr = state.sr or SR_Z
          else:
            state.sr = state.sr and (not SR_Z)

          if acc < 0:
            state.sr = state.sr or SR_N
          else:
            state.sr = state.sr and (not SR_N)

      of IrOpKind.irBranch:
        state.pc = op.imm
        cycles += 2
        return cycles

      of IrOpKind.irBranchCond:
        if evalCondition(op.cond, state.sr):
          state.pc = op.imm
        else:
          state.pc = blk.endPc
        cycles += 2
        return cycles

      of IrOpKind.irCall:
        state.core.stackPush(state.pc + 1, state.sr)
        state.pc = op.imm
        cycles += 2
        return cycles

      of IrOpKind.irReturn:
        var newPc, dummySr: uint32
        state.core.stackPop(newPc, dummySr)
        state.pc = newPc
        cycles += 2
        return cycles

      of IrOpKind.irReturnInt:
        var newPc, newSr: uint32
        state.core.stackPop(newPc, newSr)
        state.pc = newPc
        state.sr = newSr
        cycles += 2
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
        return cycles

    if not isLoopBlock:
      state.pc = blk.endPc

  if isLoopBlock:
    state.pc = loopEndPc + 1
    state.core.lc = 0
    state.sr = state.sr and (not SR_LF)

  if cycles == 0:
    cycles = 1

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
