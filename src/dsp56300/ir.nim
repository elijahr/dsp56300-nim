## Clean-room MIT Motorola DSP56300 Shared Micro-Op IR
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import dsp56300/[decode_types, decode, state, memory]

type
  IrOpKind* {.pure.} = enum
    irNop
    irCheckGen
    irLoadReg
    irStoreReg
    irLoadImm
    irLoadMem
    irStoreMem
    irAguUpdate
    irAluOp
    irBranch
    irBranchCond
    irCall
    irReturn
    irReturnInt
    irLoopDo
    irLoopDoForever
    irLoopEndDo
    irLoopBrkCc
    irLoopRep
    irHalt
    irLoadXAbs
    irLoadYAbs
    irStoreXAbs
    irStoreYAbs
    irMacFast
    irMpyFast
    irAddFast
    irSubFast
    irClrFast
    irTfrFast
    irCmpFast

  MicroOp* = object
    kind*: IrOpKind
    dst*: RegId
    src1*: RegId
    src2*: RegId
    imm*: uint32
    space*: MemSpace
    addrMode*: AddrMode
    rNum*: uint8
    nNum*: uint8
    mNum*: uint8
    cond*: ConditionCode
    aluOp*: AluOp
    isRounded*: bool
    isNeg*: bool
    isWrite*: bool
    updateCcr*: bool
    pAddr*: uint32
    expectedGen*: uint32

  FastOpKind* {.size: sizeof(uint8).} = enum
    fopNop
    fopLoadXAbsA
    fopLoadYAbsA
    fopLoadXAbsB
    fopLoadYAbsB
    fopLoadXAbsReg
    fopLoadYAbsReg
    fopStoreXAbsA1
    fopStoreYAbsA1
    fopStoreXAbsA
    fopStoreYAbsA
    fopStoreXAbsReg
    fopStoreYAbsReg
    fopLoadImmA
    fopLoadImmB
    fopLoadImmReg
    fopLoadRegReg
    fopLoadRegA
    fopLoadRegB
    fopStoreRegA1
    fopAddReg
    fopSubReg
    fopAddRegB
    fopSubRegB
    fopAddAcc
    fopSubAcc
    fopCmpReg
    fopMpyReg
    fopMpyNegReg
    fopMacReg
    fopMacNegReg
    fopMpyRegB
    fopMacRegB
    fopClrA
    fopClrB
    fopTfrA
    fopTfrB
    fopAslA
    fopAsrA
    fopAguPostInc
    fopAguPostDec
    fopAguPostIncN
    fopAguPostDecN
    fopCmpZeroA
    fopCmpImmA
    fopAddRegNoCcr
    fopSubRegNoCcr
    fopMpyRegNoCcr
    fopMacRegNoCcr
    fopCopyYtoX
    fopCopyXtoY
    fopStoreImmY
    fopStoreImmX
    fopLoadXAbsCmpImm
    fopLoadYAbsCmpImm
    fopMpyStoreY
    fopMpyStoreX
    fopMacStoreY
    fopMacStoreX
    fopAddStoreY
    fopAddStoreX
    fopSubStoreY
    fopSubStoreX
    fopMpyStoreReg
    fopLoadYAbsAddReg
    fopLoadXAbsAddReg
    fopCopyYtoY
    fopCopyXtoX
    fopLoadAddYReg
    fopLoadAddXReg
    fopLoadDualXY
    fopLoadDualXX
    fopLoadDualYY
    fopCopyMultiYtoX
    fopStoreRegLoadY
    fopStoreRegLoadX
    fopLoadAddStoreY
    fopLoadAddStoreX
    fopLoadYMpyStoreY
    fopLoadXMpyStoreY
    fopStoreRegLoadAddY
    fopCopyMultiXtoY
    fopStoreMultiImmY
    fopStoreMultiImmX
    fopNegA
    fopTstA
    fopAndRegA
    fopSexA1
    fopLoadXAbsTstA
    fopLoadYAbsTstA
    fopLoadPeriphX
    fopStorePeriphXA
    fopStorePeriphXA1
    fopCmpRegB
    fopStoreRegA
    fopStoreRegB1
    fopStoreYAbsB
    fopTstB
    fopOrRegA
    fopFallback

  FastOp* {.packed.} = object
    kind*: FastOpKind
    dst*: uint8
    src1*: uint8
    src2*: uint8
    imm*: uint32

  IrBasicBlock* = object
    startPc*: uint32
    endPc*: uint32
    generation*: uint32
    ops*: seq[MicroOp]
    fastOps*: seq[FastOp]
    fastOpsBuilt*: bool
    isHot*: bool
    execCount*: uint64
    isLoopBlock*: bool
    loopIterations*: uint32
    loopEndPc*: uint32
    hasBranch*: bool
    hasCondBranch*: bool
    branchCond*: ConditionCode
    condTruthTable*: uint8
    branchTargetPc*: uint32
    writesPeriph*: bool
    nextBlk*: pointer
    branchBlk*: pointer
    numFastOps*: int32
    fastOpsArr*: ptr UncheckedArray[FastOp]

  DspState* = object
    core*: Dsp56300State
    mem*: Dsp56300Memory
    pRamGen*: seq[uint32]

proc canonicalizeOp*(op: MicroOp): MicroOp {.inline.} =
  result = op
  case op.kind
  of IrOpKind.irLoadXAbs:
    result.kind = IrOpKind.irLoadMem
    result.space = MemSpace.memX
    result.addrMode = AddrMode.amAbsolute
  of IrOpKind.irLoadYAbs:
    result.kind = IrOpKind.irLoadMem
    result.space = MemSpace.memY
    result.addrMode = AddrMode.amAbsolute
  of IrOpKind.irStoreXAbs:
    result.kind = IrOpKind.irStoreMem
    result.space = MemSpace.memX
    result.addrMode = AddrMode.amAbsolute
  of IrOpKind.irStoreYAbs:
    result.kind = IrOpKind.irStoreMem
    result.space = MemSpace.memY
    result.addrMode = AddrMode.amAbsolute
  of IrOpKind.irMacFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opMac
  of IrOpKind.irMpyFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opMpy
  of IrOpKind.irAddFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opAdd
  of IrOpKind.irSubFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opSub
  of IrOpKind.irClrFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opClr
  of IrOpKind.irTfrFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opTfr
  of IrOpKind.irCmpFast:
    result.kind = IrOpKind.irAluOp
    result.aluOp = AluOp.opCmp
  else:
    discard

proc newDspState*(pRamWords: int = P_RAM_MAX_WORDS): DspState =
  result.core.reset()
  result.mem = initMemory()
  result.pRamGen = newSeq[uint32](pRamWords)
  for i in 0 ..< pRamWords:
    result.pRamGen[i] = 1'u32

# Ergonomic Accessors forward to core & mem
template pc*(s: DspState): uint32 =
  s.core.pc

template `pc=`*(s: var DspState, v: uint32) =
  s.core.pc = v

template sr*(s: DspState): uint32 =
  s.core.sr

template `sr=`*(s: var DspState, v: uint32) =
  s.core.sr = v

template x0*(s: DspState): uint32 =
  s.core.x0

template `x0=`*(s: var DspState, v: uint32) =
  s.core.x0 = v

template x1*(s: DspState): uint32 =
  s.core.x1

template `x1=`*(s: var DspState, v: uint32) =
  s.core.x1 = v

template y0*(s: DspState): uint32 =
  s.core.y0

template `y0=`*(s: var DspState, v: uint32) =
  s.core.y0 = v

template y1*(s: DspState): uint32 =
  s.core.y1

template `y1=`*(s: var DspState, v: uint32) =
  s.core.y1 = v

template a2*(s: DspState): uint8 =
  s.core.a2

template `a2=`*(s: var DspState, v: uint8) =
  s.core.a2 = v

template a1*(s: DspState): uint32 =
  s.core.a1

template `a1=`*(s: var DspState, v: uint32) =
  s.core.a1 = v

template a0*(s: DspState): uint32 =
  s.core.a0

template `a0=`*(s: var DspState, v: uint32) =
  s.core.a0 = v

template b2*(s: DspState): uint8 =
  s.core.b2

template `b2=`*(s: var DspState, v: uint8) =
  s.core.b2 = v

template b1*(s: DspState): uint32 =
  s.core.b1

template `b1=`*(s: var DspState, v: uint32) =
  s.core.b1 = v

template b0*(s: DspState): uint32 =
  s.core.b0

template `b0=`*(s: var DspState, v: uint32) =
  s.core.b0 = v

template r*(s: DspState): untyped =
  s.core.r

template n*(s: DspState): untyped =
  s.core.n

template m*(s: DspState): untyped =
  s.core.m

template pRam*(s: DspState): untyped =
  s.mem.pRam

template xRam*(s: DspState): untyped =
  s.mem.xRam

template yRam*(s: DspState): untyped =
  s.mem.yRam

proc getAccA*(s: DspState): int64 {.inline.} =
  s.core.getA()

proc setAccA*(s: var DspState, v: int64) {.inline.} =
  s.core.setA(v)

proc getAccB*(s: DspState): int64 {.inline.} =
  s.core.getB()

proc setAccB*(s: var DspState, v: int64) {.inline.} =
  s.core.setB(v)

proc validateBlock*(state: DspState, blk: IrBasicBlock): bool =
  ## Validates that no P-RAM word in the lifted block has been modified since lifting.
  let addrIdx = int(blk.startPc)
  if addrIdx < state.pRamGen.len:
    if state.pRamGen[addrIdx] != blk.generation:
      return false
  return true

proc buildFastOps*(blk: var IrBasicBlock)

proc liftBasicBlock*(
    state: DspState, startPc: uint32, maxWords: int = 64
): IrBasicBlock =
  result.startPc = startPc
  result.generation =
    if int(startPc) < state.pRamGen.len:
      state.pRamGen[int(startPc)]
    else:
      1'u32
  result.ops = @[]

  var curPc = startPc
  var wordsRead = 0

  while wordsRead < maxWords and int(curPc) < state.mem.pRam.len:
    let w0 = state.mem.pRam[int(curPc)]
    let w1 =
      if int(curPc + 1) < state.mem.pRam.len:
        state.mem.pRam[int(curPc + 1)]
      else:
        0'u32

    let inst = decodeInstruction([w0, w1], curPc)
    let instWords = int(inst.words)

    # Decode special flow / control opcodes first
    if inst.ctrlOp != ControlOp.ctrlNone:
      case inst.ctrlOp
      of ControlOp.ctrlRts:
        result.ops.add(MicroOp(kind: IrOpKind.irReturn, pAddr: curPc))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlRti:
        result.ops.add(MicroOp(kind: IrOpKind.irReturnInt, pAddr: curPc))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlJmp, ControlOp.ctrlBra:
        if inst.targetAddr > curPc and (inst.targetAddr - curPc) <= 256 and
            inst.targetAddr < uint32(state.mem.pRam.len) and
            state.mem.pRam[int(inst.targetAddr)] != 0'u32 and
            (wordsRead + instWords + 2) < maxWords:
          curPc = inst.targetAddr
          wordsRead += instWords
          continue
        else:
          result.hasBranch = true
          result.branchTargetPc = inst.targetAddr
          curPc += uint32(instWords)
          wordsRead += instWords
          break
      of ControlOp.ctrlJcc:
        result.hasCondBranch = true
        result.branchCond = inst.cond
        result.condTruthTable =
          case inst.cond
          of ConditionCode.ccGT: 1'u8
          of ConditionCode.ccNE: 3'u8
          of ConditionCode.ccGE: 5'u8
          of ConditionCode.ccLT: 10'u8
          of ConditionCode.ccEQ: 12'u8
          of ConditionCode.ccLE: 14'u8
          else: 0'u8
        result.branchTargetPc = inst.targetAddr
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlJscc:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irCall, imm: inst.targetAddr, cond: inst.cond, pAddr: curPc
          )
        )
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlDo:
        result.isLoopBlock = true
        result.loopIterations = inst.immValue
        result.loopEndPc = inst.targetAddr
        result.ops.add(
          MicroOp(kind: IrOpKind.irLoopDo, imm: inst.immValue, pAddr: inst.targetAddr)
        )
      of ControlOp.ctrlDoForever:
        result.ops.add(MicroOp(kind: IrOpKind.irLoopDoForever, pAddr: inst.targetAddr))
      of ControlOp.ctrlEndDo:
        result.ops.add(MicroOp(kind: IrOpKind.irLoopEndDo))
      of ControlOp.ctrlBrkCc:
        result.ops.add(MicroOp(kind: IrOpKind.irLoopBrkCc, cond: inst.cond))
      of ControlOp.ctrlRep:
        result.ops.add(MicroOp(kind: IrOpKind.irLoopRep, imm: inst.immValue))
      of ControlOp.ctrlIllegal, ControlOp.ctrlStop, ControlOp.ctrlWait:
        result.ops.add(MicroOp(kind: IrOpKind.irHalt))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      else:
        discard

    # If instruction has a parallel move, emit micro-ops
    case inst.parallel.kind
    of ParallelMoveKind.pmNone:
      discard
    of ParallelMoveKind.pmImmediateShort:
      result.ops.add(
        MicroOp(
          kind: IrOpKind.irLoadImm,
          dst: inst.parallel.immDst,
          imm: inst.parallel.immShort,
        )
      )
    of ParallelMoveKind.pmRegToReg:
      result.ops.add(
        MicroOp(
          kind: IrOpKind.irLoadReg,
          dst: inst.parallel.regDst,
          src1: inst.parallel.regSrc,
        )
      )
    of ParallelMoveKind.pmAddrUpdate:
      result.ops.add(
        MicroOp(
          kind: IrOpKind.irAguUpdate,
          rNum: inst.parallel.uReg,
          addrMode: inst.parallel.uMode,
        )
      )
    of ParallelMoveKind.pmXMem, ParallelMoveKind.pmYMem:
      if inst.parallel.memMode == AddrMode.amImmediate:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irLoadImm,
            dst: inst.parallel.memReg,
            imm: inst.parallel.memAddr,
          )
        )
      elif not inst.parallel.isWrite:
        if inst.parallel.memMode == AddrMode.amAbsolute:
          let k =
            if inst.parallel.memSpace == MemSpace.memX:
              IrOpKind.irLoadXAbs
            else:
              IrOpKind.irLoadYAbs
          result.ops.add(
            MicroOp(kind: k, dst: inst.parallel.memReg, imm: inst.parallel.memAddr)
          )
        else:
          result.ops.add(
            MicroOp(
              kind: IrOpKind.irLoadMem,
              dst: inst.parallel.memReg,
              space: inst.parallel.memSpace,
              addrMode: inst.parallel.memMode,
              rNum: inst.parallel.memRNum,
              imm: inst.parallel.memAddr,
            )
          )
      else:
        if inst.parallel.memAddr >= 0xFFFF80'u32:
          result.writesPeriph = true
        if inst.parallel.memMode == AddrMode.amAbsolute:
          let k =
            if inst.parallel.memSpace == MemSpace.memX:
              IrOpKind.irStoreXAbs
            else:
              IrOpKind.irStoreYAbs
          result.ops.add(
            MicroOp(kind: k, src1: inst.parallel.memReg, imm: inst.parallel.memAddr)
          )
        else:
          result.ops.add(
            MicroOp(
              kind: IrOpKind.irStoreMem,
              src1: inst.parallel.memReg,
              space: inst.parallel.memSpace,
              addrMode: inst.parallel.memMode,
              rNum: inst.parallel.memRNum,
              imm: inst.parallel.memAddr,
            )
          )

      if inst.parallel.memMode in {
        AddrMode.amPostInc, AddrMode.amPostDec, AddrMode.amPostIncN, AddrMode.amPostDecN
      }:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irAguUpdate,
            rNum: inst.parallel.memRNum,
            addrMode: inst.parallel.memMode,
          )
        )
    of ParallelMoveKind.pmXYDual:
      # Dual Move: reads observe pre-ALU values!
      if not inst.parallel.xWrite:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irLoadMem,
            dst: inst.parallel.xReg,
            space: MemSpace.memX,
            addrMode: inst.parallel.xMode,
            rNum: inst.parallel.xRNum,
          )
        )
      else:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irStoreMem,
            src1: inst.parallel.xReg,
            space: MemSpace.memX,
            addrMode: inst.parallel.xMode,
            rNum: inst.parallel.xRNum,
          )
        )

      if not inst.parallel.yWrite:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irLoadMem,
            dst: inst.parallel.yReg,
            space: MemSpace.memY,
            addrMode: inst.parallel.yMode,
            rNum: inst.parallel.yRNum,
          )
        )
      else:
        result.ops.add(
          MicroOp(
            kind: IrOpKind.irStoreMem,
            src1: inst.parallel.yReg,
            space: MemSpace.memY,
            addrMode: inst.parallel.yMode,
            rNum: inst.parallel.yRNum,
          )
        )

      # AGU post updates for both X and Y
      result.ops.add(
        MicroOp(
          kind: IrOpKind.irAguUpdate,
          rNum: inst.parallel.xRNum,
          addrMode: inst.parallel.xMode,
        )
      )
      result.ops.add(
        MicroOp(
          kind: IrOpKind.irAguUpdate,
          rNum: inst.parallel.yRNum,
          addrMode: inst.parallel.yMode,
        )
      )
    of ParallelMoveKind.pmIfCc:
      discard # Handled in ALU conditional execution
    else:
      discard

    # Emit ALU Micro-Op
    if inst.aluOp != AluOp.opNop and inst.aluOp != AluOp.opMove:
      if inst.parallel.kind != ParallelMoveKind.pmIfCc:
        if (inst.aluOp == AluOp.opMac or inst.aluOp == AluOp.opMacr) and
            inst.src1Reg in {RegId.regX0 .. RegId.regY1} and
            inst.src2Reg in {RegId.regX0 .. RegId.regY1}:
          result.ops.add(
            MicroOp(
              kind: IrOpKind.irMacFast,
              dst: inst.dstReg,
              src1: inst.src1Reg,
              src2: inst.src2Reg,
              isNeg: inst.isNegMpy,
            )
          )
        elif (inst.aluOp == AluOp.opMpy or inst.aluOp == AluOp.opMpyr) and
            inst.src1Reg in {RegId.regX0 .. RegId.regY1} and
            inst.src2Reg in {RegId.regX0 .. RegId.regY1}:
          result.ops.add(
            MicroOp(
              kind: IrOpKind.irMpyFast,
              dst: inst.dstReg,
              src1: inst.src1Reg,
              src2: inst.src2Reg,
              isNeg: inst.isNegMpy,
            )
          )
        elif inst.aluOp == AluOp.opAdd and not inst.isNegMpy:
          result.ops.add(
            MicroOp(kind: IrOpKind.irAddFast, dst: inst.dstReg, src1: inst.src1Reg)
          )
        elif inst.aluOp == AluOp.opSub or (inst.aluOp == AluOp.opAdd and inst.isNegMpy):
          result.ops.add(
            MicroOp(kind: IrOpKind.irSubFast, dst: inst.dstReg, src1: inst.src1Reg)
          )
        elif inst.aluOp == AluOp.opCmp:
          result.ops.add(
            MicroOp(kind: IrOpKind.irCmpFast, dst: inst.dstReg, src1: inst.src1Reg)
          )
        elif inst.aluOp == AluOp.opClr:
          result.ops.add(MicroOp(kind: IrOpKind.irClrFast, dst: inst.dstReg))
        elif inst.aluOp == AluOp.opTfr:
          result.ops.add(
            MicroOp(kind: IrOpKind.irTfrFast, dst: inst.dstReg, src1: inst.src1Reg)
          )
        else:
          var op = MicroOp(
            kind: IrOpKind.irAluOp,
            aluOp: inst.aluOp,
            dst: inst.dstReg,
            src1: inst.src1Reg,
            src2: inst.src2Reg,
            isRounded: inst.isRounded,
            isNeg: inst.isNegMpy,
          )
          result.ops.add(op)
      else:
        var op = MicroOp(
          kind: IrOpKind.irAluOp,
          aluOp: inst.aluOp,
          dst: inst.dstReg,
          src1: inst.src1Reg,
          src2: inst.src2Reg,
          isRounded: inst.isRounded,
          isNeg: inst.isNegMpy,
          cond: inst.parallel.cc,
          updateCcr: inst.parallel.updateCcr,
        )
        result.ops.add(op)
    elif result.ops.len == 0 and inst.parallel.kind == ParallelMoveKind.pmNone and
        inst.ctrlOp == ControlOp.ctrlNone:
      result.ops.add(MicroOp(kind: IrOpKind.irNop))

    curPc += uint32(instWords)
    wordsRead += instWords

  result.endPc = curPc
  result.buildFastOps()

proc buildFastOps*(blk: var IrBasicBlock) =
  blk.fastOpsBuilt = true
  let nOps = blk.ops.len
  if nOps == 0:
    blk.fastOps = @[]
    blk.numFastOps = 0
    blk.fastOpsArr = nil
    return

  # Backward liveness analysis for CCR Z/N flags
  var ccrNeeded = newSeq[bool](nOps)
  var needed = true
  for i in countdown(nOps - 1, 0):
    let op = addr blk.ops[i]
    case op.kind
    of IrOpKind.irLoopBrkCc, IrOpKind.irAluOp:
      needed = true
    of IrOpKind.irAddFast, IrOpKind.irSubFast, IrOpKind.irCmpFast, IrOpKind.irMpyFast,
        IrOpKind.irMacFast, IrOpKind.irClrFast, IrOpKind.irTfrFast:
      ccrNeeded[i] = needed
      needed = false
    else:
      discard

  blk.fastOps = newSeqOfCap[FastOp](nOps)
  for idx in 0 ..< nOps:
    let op = addr blk.ops[idx]
    var f: FastOp
    f.dst = uint8(op.dst)
    f.src1 = uint8(op.src1)
    f.src2 = uint8(op.src2)
    f.imm = op.imm

    case op.kind
    of IrOpKind.irNop, IrOpKind.irCheckGen:
      f.kind = fopNop
      blk.fastOps.add(f)
    of IrOpKind.irLoadXAbs:
      if op.imm >= 0xFFFF80'u32:
        if op.dst == RegId.regA:
          f.kind = fopLoadPeriphX
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      elif op.dst == RegId.regA:
        if blk.fastOps.len > 0 and blk.fastOps[^1].kind == fopStoreXAbsA1 and
            blk.fastOps[^1].imm == op.imm:
          f.kind = fopNop
        else:
          f.kind = fopLoadXAbsA
      elif op.dst == RegId.regB:
        f.kind = fopLoadXAbsB
      elif op.dst <= RegId.regY1:
        f.kind = fopLoadXAbsReg
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irLoadYAbs:
      if op.imm >= 0xFFFF80'u32:
        f.kind = fopFallback
        f.imm = uint32(idx)
      elif op.dst == RegId.regA:
        if blk.fastOps.len > 0 and blk.fastOps[^1].kind == fopStoreYAbsA1 and
            blk.fastOps[^1].imm == op.imm:
          f.kind = fopNop
        else:
          f.kind = fopLoadYAbsA
      elif op.dst == RegId.regB:
        f.kind = fopLoadYAbsB
      elif op.dst <= RegId.regY1:
        f.kind = fopLoadYAbsReg
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irStoreXAbs:
      if op.imm >= 0xFFFF80'u32:
        if op.src1 == RegId.regA:
          f.kind = fopStorePeriphXA
        elif op.src1 == RegId.regA1:
          f.kind = fopStorePeriphXA1
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      elif op.src1 == RegId.regA1:
        f.kind = fopStoreXAbsA1
      elif op.src1 == RegId.regA:
        f.kind = fopStoreXAbsA
      elif op.src1 <= RegId.regY1:
        f.kind = fopStoreXAbsReg
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irStoreYAbs:
      if op.imm >= 0xFFFF80'u32:
        f.kind = fopFallback
        f.imm = uint32(idx)
      elif op.src1 == RegId.regA1:
        f.kind = fopStoreYAbsA1
      elif op.src1 == RegId.regA:
        f.kind = fopStoreYAbsA
      elif op.src1 == RegId.regB:
        f.kind = fopStoreYAbsB
      elif op.src1 <= RegId.regY1:
        f.kind = fopStoreYAbsReg
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irLoadImm:
      if op.dst == RegId.regA:
        f.kind = fopLoadImmA
      elif op.dst == RegId.regB:
        f.kind = fopLoadImmB
      elif op.dst <= RegId.regY1 or (op.dst >= RegId.regR0 and op.dst <= RegId.regM7):
        f.kind = fopLoadImmReg
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irLoadReg, IrOpKind.irStoreReg:
      if op.dst == RegId.regA:
        if op.src1 <= RegId.regY1:
          f.kind = fopLoadRegA
        elif op.src1 == RegId.regA1:
          f.kind = fopSexA1
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      elif op.dst == RegId.regB:
        if op.src1 <= RegId.regY1:
          f.kind = fopLoadRegB
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      elif op.src1 == RegId.regA and op.dst <= RegId.regY1:
        f.kind = fopStoreRegA
      elif op.src1 == RegId.regA1 and op.dst <= RegId.regY1:
        f.kind = fopStoreRegA1
      elif op.src1 == RegId.regB1 and op.dst <= RegId.regY1:
        f.kind = fopStoreRegB1
      elif op.src1 <= RegId.regY1 and op.dst <= RegId.regY1:
        f.kind = fopLoadRegReg
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irAddFast:
      if op.dst == RegId.regA:
        if op.src1 <= RegId.regY1:
          f.kind = if ccrNeeded[idx]: fopAddReg else: fopAddRegNoCcr
        elif op.src1 == RegId.regA or op.src1 == RegId.regB:
          f.kind = fopAddAcc
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      elif op.dst == RegId.regB and op.src1 <= RegId.regY1:
        f.kind = fopAddRegB
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irSubFast:
      if op.dst == RegId.regA:
        if op.src1 <= RegId.regY1:
          f.kind = if ccrNeeded[idx]: fopSubReg else: fopSubRegNoCcr
        elif op.src1 == RegId.regA or op.src1 == RegId.regB:
          f.kind = fopSubAcc
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      elif op.dst == RegId.regB and op.src1 <= RegId.regY1:
        f.kind = fopSubRegB
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irCmpFast:
      if op.dst == RegId.regA and op.src1 <= RegId.regY1:
        if idx > 0 and blk.ops[idx - 1].kind == IrOpKind.irLoadImm and
            blk.ops[idx - 1].dst == op.src1:
          let immVal = blk.ops[idx - 1].imm
          if immVal == 0:
            f.kind = fopCmpZeroA
          else:
            f.kind = fopCmpImmA
            f.imm = immVal
          var regUsedLater = false
          for k in (idx + 1) ..< nOps:
            if blk.ops[k].src1 == op.src1 or blk.ops[k].src2 == op.src1:
              regUsedLater = true
              break
          if not regUsedLater and blk.fastOps.len > 0 and
              blk.fastOps[^1].kind == fopLoadImmReg and
              blk.fastOps[^1].dst == uint8(op.src1):
            blk.fastOps[^1].kind = fopNop
        else:
          f.kind = fopCmpReg
      elif op.dst == RegId.regB and op.src1 <= RegId.regY1:
        f.kind = fopCmpRegB
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irMpyFast:
      if op.dst == RegId.regA:
        if op.isNeg:
          f.kind = fopMpyNegReg
        else:
          f.kind = if ccrNeeded[idx]: fopMpyReg else: fopMpyRegNoCcr
      elif op.dst == RegId.regB:
        f.kind = fopMpyRegB
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irMacFast:
      if op.dst == RegId.regA:
        if op.isNeg:
          f.kind = fopMacNegReg
        else:
          f.kind = if ccrNeeded[idx]: fopMacReg else: fopMacRegNoCcr
      elif op.dst == RegId.regB:
        f.kind = fopMacRegB
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irClrFast:
      f.kind = if op.dst == RegId.regB: fopClrB else: fopClrA
      blk.fastOps.add(f)
    of IrOpKind.irTfrFast:
      f.kind = if op.dst == RegId.regB: fopTfrB else: fopTfrA
      blk.fastOps.add(f)
    of IrOpKind.irAguUpdate:
      if op.rNum <= 7:
        f.src1 = op.rNum
        case op.addrMode
        of AddrMode.amPostInc:
          f.kind = fopAguPostInc
        of AddrMode.amPostDec:
          f.kind = fopAguPostDec
        of AddrMode.amPostIncN:
          f.kind = fopAguPostIncN
        of AddrMode.amPostDecN:
          f.kind = fopAguPostDecN
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    of IrOpKind.irAluOp:
      case op.aluOp
      of AluOp.opAsl:
        if op.dst == RegId.regA:
          f.kind = fopAslA
        else:
          (f.kind = fopFallback; f.imm = uint32(idx))
      of AluOp.opAsr:
        if op.dst == RegId.regA:
          f.kind = fopAsrA
        else:
          (f.kind = fopFallback; f.imm = uint32(idx))
      of AluOp.opNeg:
        if op.dst == RegId.regA:
          f.kind = fopNegA
        else:
          (f.kind = fopFallback; f.imm = uint32(idx))
      of AluOp.opTst:
        if op.dst == RegId.regA:
          f.kind = fopTstA
        elif op.dst == RegId.regB:
          f.kind = fopTstB
        else:
          (f.kind = fopFallback; f.imm = uint32(idx))
      of AluOp.opAnd:
        if op.dst == RegId.regA and op.src1 <= RegId.regY1:
          f.kind = fopAndRegA
          f.src1 = uint8(op.src1)
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      of AluOp.opOr:
        if op.dst == RegId.regA and op.src1 <= RegId.regY1:
          f.kind = fopOrRegA
          f.src1 = uint8(op.src1)
        else:
          f.kind = fopFallback
          f.imm = uint32(idx)
      else:
        f.kind = fopFallback
        f.imm = uint32(idx)
      blk.fastOps.add(f)
    else:
      f.kind = fopFallback
      f.imm = uint32(idx)
      blk.fastOps.add(f)

  # Peephole optimizer and super-operator fusion
  let numFast = blk.fastOps.len
  if numFast > 1:
    var accDeadAfter = newSeq[bool](numFast)
    var aDead = false
    for k in countdown(numFast - 1, 0):
      accDeadAfter[k] = aDead
      case blk.fastOps[k].kind
      of fopLoadXAbsA, fopLoadYAbsA, fopLoadImmA, fopClrA, fopMpyReg, fopMpyRegNoCcr,
          fopMpyNegReg, fopLoadXAbsTstA, fopLoadYAbsTstA, fopLoadPeriphX:
        aDead = true
      of fopStoreXAbsA1, fopStoreYAbsA1, fopStoreXAbsA, fopStoreYAbsA, fopStoreRegA1,
          fopAddReg, fopAddRegNoCcr, fopSubReg, fopSubRegNoCcr, fopMacReg,
          fopMacRegNoCcr, fopMacNegReg, fopCmpReg, fopCmpZeroA, fopCmpImmA, fopAslA,
          fopAsrA, fopTfrB, fopNegA, fopTstA, fopAndRegA, fopSexA1, fopStoreRegA,
          fopOrRegA, fopStorePeriphXA, fopStorePeriphXA1:
        aDead = false
      else:
        discard

    var passChanged = true
    var passCount = 0
    while passChanged and passCount < 4:
      passChanged = false
      inc passCount
      var i = 0
      while i < numFast:
        if blk.fastOps[i].kind == fopNop:
          inc i
          continue
        var j = i + 1
        while j < numFast and blk.fastOps[j].kind == fopNop:
          inc j
        if j >= numFast:
          break

        # 1. LoadX/Y -> StoreRegA1 when accA is dead
        if blk.fastOps[i].kind == fopLoadXAbsA and blk.fastOps[j].kind == fopStoreRegA1 and
            accDeadAfter[j]:
          blk.fastOps[i].kind = fopLoadXAbsReg
          blk.fastOps[i].dst = blk.fastOps[j].dst
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue
        elif blk.fastOps[i].kind == fopLoadYAbsA and blk.fastOps[j].kind == fopStoreRegA1 and
            accDeadAfter[j]:
          blk.fastOps[i].kind = fopLoadYAbsReg
          blk.fastOps[i].dst = blk.fastOps[j].dst
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 1b. Load Y Abs + Tst A -> LoadYAbsTstA
        elif blk.fastOps[i].kind == fopLoadYAbsA and blk.fastOps[j].kind == fopTstA:
          blk.fastOps[i].kind = fopLoadYAbsTstA
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 1c. Load X Abs + Tst A -> LoadXAbsTstA
        elif blk.fastOps[i].kind == fopLoadXAbsA and blk.fastOps[j].kind == fopTstA:
          blk.fastOps[i].kind = fopLoadXAbsTstA
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 2. Copy Y -> X
        elif blk.fastOps[i].kind == fopLoadYAbsA and (
          blk.fastOps[j].kind == fopStoreXAbsA1 or blk.fastOps[j].kind == fopStoreXAbsA
        ):
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopCopyYtoX
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 3. Copy X -> Y
        elif blk.fastOps[i].kind == fopLoadXAbsA and (
          blk.fastOps[j].kind == fopStoreYAbsA1 or blk.fastOps[j].kind == fopStoreYAbsA
        ):
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopCopyXtoY
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 4. Store Imm -> Y
        elif blk.fastOps[i].kind == fopLoadImmA and (
          blk.fastOps[j].kind == fopStoreYAbsA1 or blk.fastOps[j].kind == fopStoreYAbsA
        ):
          let dst = blk.fastOps[j].imm
          if dst < 65536:
            blk.fastOps[i].kind = fopStoreImmY
            blk.fastOps[i].src1 = uint8(dst and 0xFF)
            blk.fastOps[i].src2 = uint8(dst shr 8)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 5. Store Imm -> X
        elif blk.fastOps[i].kind == fopLoadImmA and (
          blk.fastOps[j].kind == fopStoreXAbsA1 or blk.fastOps[j].kind == fopStoreXAbsA
        ):
          let dst = blk.fastOps[j].imm
          if dst < 65536:
            blk.fastOps[i].kind = fopStoreImmX
            blk.fastOps[i].src1 = uint8(dst and 0xFF)
            blk.fastOps[i].src2 = uint8(dst shr 8)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 6. Load X -> Cmp Imm / Zero
        elif blk.fastOps[i].kind == fopLoadXAbsA and
            (blk.fastOps[j].kind == fopCmpImmA or blk.fastOps[j].kind == fopCmpZeroA):
          let src = blk.fastOps[i].imm
          if src < 65536:
            blk.fastOps[i].kind = fopLoadXAbsCmpImm
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm =
              if blk.fastOps[j].kind == fopCmpZeroA:
                0'u32
              else:
                blk.fastOps[j].imm
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 7. Load Y -> Cmp Imm / Zero
        elif blk.fastOps[i].kind == fopLoadYAbsA and
            (blk.fastOps[j].kind == fopCmpImmA or blk.fastOps[j].kind == fopCmpZeroA):
          let src = blk.fastOps[i].imm
          if src < 65536:
            blk.fastOps[i].kind = fopLoadYAbsCmpImm
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm =
              if blk.fastOps[j].kind == fopCmpZeroA:
                0'u32
              else:
                blk.fastOps[j].imm
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 8. Mpy -> Store Y
        elif blk.fastOps[i].kind == fopMpyRegNoCcr and
            blk.fastOps[j].kind == fopStoreYAbsA1:
          blk.fastOps[i].kind = fopMpyStoreY
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 9. Mpy -> Store X
        elif blk.fastOps[i].kind == fopMpyRegNoCcr and
            blk.fastOps[j].kind == fopStoreXAbsA1:
          blk.fastOps[i].kind = fopMpyStoreX
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 10. Mac -> Store Y
        elif blk.fastOps[i].kind == fopMacRegNoCcr and
            blk.fastOps[j].kind == fopStoreYAbsA1:
          blk.fastOps[i].kind = fopMacStoreY
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 11. Mac -> Store X
        elif blk.fastOps[i].kind == fopMacRegNoCcr and
            blk.fastOps[j].kind == fopStoreXAbsA1:
          blk.fastOps[i].kind = fopMacStoreX
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 12. Add -> Store Y
        elif blk.fastOps[i].kind == fopAddRegNoCcr and
            blk.fastOps[j].kind == fopStoreYAbsA1:
          blk.fastOps[i].kind = fopAddStoreY
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 13. Add -> Store X
        elif blk.fastOps[i].kind == fopAddRegNoCcr and
            blk.fastOps[j].kind == fopStoreXAbsA1:
          blk.fastOps[i].kind = fopAddStoreX
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 14. Sub -> Store Y
        elif blk.fastOps[i].kind == fopSubRegNoCcr and
            blk.fastOps[j].kind == fopStoreYAbsA1:
          blk.fastOps[i].kind = fopSubStoreY
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 15. Sub -> Store X
        elif blk.fastOps[i].kind == fopSubRegNoCcr and
            blk.fastOps[j].kind == fopStoreXAbsA1:
          blk.fastOps[i].kind = fopSubStoreX
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 16. Mpy -> Store Reg
        elif blk.fastOps[i].kind == fopMpyRegNoCcr and
            blk.fastOps[j].kind == fopStoreRegA1:
          blk.fastOps[i].kind = fopMpyStoreReg
          blk.fastOps[i].dst = blk.fastOps[j].dst
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 17. Load Y Abs A -> Add Reg
        elif blk.fastOps[i].kind == fopLoadYAbsA and
            blk.fastOps[j].kind == fopAddRegNoCcr:
          blk.fastOps[i].kind = fopLoadYAbsAddReg
          blk.fastOps[i].src1 = blk.fastOps[j].src1
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 18. Load X Abs A -> Add Reg
        elif blk.fastOps[i].kind == fopLoadXAbsA and
            blk.fastOps[j].kind == fopAddRegNoCcr:
          blk.fastOps[i].kind = fopLoadXAbsAddReg
          blk.fastOps[i].src1 = blk.fastOps[j].src1
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 19. Copy Y -> Y
        elif blk.fastOps[i].kind == fopLoadYAbsA and (
          blk.fastOps[j].kind == fopStoreYAbsA1 or blk.fastOps[j].kind == fopStoreYAbsA
        ):
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopCopyYtoY
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 20. Copy X -> X
        elif blk.fastOps[i].kind == fopLoadXAbsA and (
          blk.fastOps[j].kind == fopStoreXAbsA1 or blk.fastOps[j].kind == fopStoreXAbsA
        ):
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopCopyXtoX
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 21. Load Y Abs Reg -> Add Reg (when dst matches src1)
        elif blk.fastOps[i].kind == fopLoadYAbsReg and
            blk.fastOps[j].kind == fopAddRegNoCcr and
            blk.fastOps[i].dst == blk.fastOps[j].src1:
          blk.fastOps[i].kind = fopLoadAddYReg
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 22. Load X Abs Reg -> Add Reg (when dst matches src1)
        elif blk.fastOps[i].kind == fopLoadXAbsReg and
            blk.fastOps[j].kind == fopAddRegNoCcr and
            blk.fastOps[i].dst == blk.fastOps[j].src1:
          blk.fastOps[i].kind = fopLoadAddXReg
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 23. Load Dual X and Y registers (both XY and YX order)
        elif blk.fastOps[i].kind == fopLoadXAbsReg and
            blk.fastOps[j].kind == fopLoadYAbsReg:
          let addrX = blk.fastOps[i].imm
          let addrY = blk.fastOps[j].imm
          if addrX < 65536 and addrY < 65536:
            blk.fastOps[i].kind = fopLoadDualXY
            blk.fastOps[i].src1 = blk.fastOps[i].dst
            blk.fastOps[i].src2 = blk.fastOps[j].dst
            blk.fastOps[i].imm = addrX or (addrY shl 16)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue
        elif blk.fastOps[i].kind == fopLoadYAbsReg and
            blk.fastOps[j].kind == fopLoadXAbsReg:
          let addrY = blk.fastOps[i].imm
          let addrX = blk.fastOps[j].imm
          if addrX < 65536 and addrY < 65536:
            blk.fastOps[i].kind = fopLoadDualXY
            blk.fastOps[i].src1 = blk.fastOps[j].dst
            blk.fastOps[i].src2 = blk.fastOps[i].dst
            blk.fastOps[i].imm = addrX or (addrY shl 16)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 24. Load Dual X and X registers
        elif blk.fastOps[i].kind == fopLoadXAbsReg and
            blk.fastOps[j].kind == fopLoadXAbsReg and
            blk.fastOps[i].dst != blk.fastOps[j].dst:
          let addr1 = blk.fastOps[i].imm
          let addr2 = blk.fastOps[j].imm
          if addr1 < 65536 and addr2 < 65536:
            blk.fastOps[i].kind = fopLoadDualXX
            blk.fastOps[i].src1 = blk.fastOps[i].dst
            blk.fastOps[i].src2 = blk.fastOps[j].dst
            blk.fastOps[i].imm = addr1 or (addr2 shl 16)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 25. Load Dual Y and Y registers
        elif blk.fastOps[i].kind == fopLoadYAbsReg and
            blk.fastOps[j].kind == fopLoadYAbsReg and
            blk.fastOps[i].dst != blk.fastOps[j].dst:
          let addr1 = blk.fastOps[i].imm
          let addr2 = blk.fastOps[j].imm
          if addr1 < 65536 and addr2 < 65536:
            blk.fastOps[i].kind = fopLoadDualYY
            blk.fastOps[i].src1 = blk.fastOps[i].dst
            blk.fastOps[i].src2 = blk.fastOps[j].dst
            blk.fastOps[i].imm = addr1 or (addr2 shl 16)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 26. Store Reg A1 -> Load Y Abs Reg
        elif blk.fastOps[i].kind == fopStoreRegA1 and
            blk.fastOps[j].kind == fopLoadYAbsReg and
            blk.fastOps[i].dst != blk.fastOps[j].dst:
          blk.fastOps[i].kind = fopStoreRegLoadY
          blk.fastOps[i].src1 = blk.fastOps[j].dst
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 27. Store Reg A1 -> Load X Abs Reg
        elif blk.fastOps[i].kind == fopStoreRegA1 and
            blk.fastOps[j].kind == fopLoadXAbsReg and
            blk.fastOps[i].dst != blk.fastOps[j].dst:
          blk.fastOps[i].kind = fopStoreRegLoadX
          blk.fastOps[i].src1 = blk.fastOps[j].dst
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 28. Load Add Y Reg -> Store Y Abs A1
        elif blk.fastOps[i].kind == fopLoadAddYReg and
            blk.fastOps[j].kind == fopStoreYAbsA1:
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopLoadAddStoreY
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 29. Copy Multi Y to X
        elif (
          blk.fastOps[i].kind == fopCopyYtoX or blk.fastOps[i].kind == fopCopyMultiYtoX
        ) and (
          blk.fastOps[j].kind == fopCopyYtoX or blk.fastOps[j].kind == fopCopyMultiYtoX
        ):
          let src1 = uint32(blk.fastOps[i].src1) or (uint32(blk.fastOps[i].src2) shl 8)
          let dst1 = blk.fastOps[i].imm
          let run1 =
            if blk.fastOps[i].kind == fopCopyMultiYtoX:
              uint32(blk.fastOps[i].dst)
            else:
              1'u32
          let src2 = uint32(blk.fastOps[j].src1) or (uint32(blk.fastOps[j].src2) shl 8)
          let dst2 = blk.fastOps[j].imm
          let run2 =
            if blk.fastOps[j].kind == fopCopyMultiYtoX:
              uint32(blk.fastOps[j].dst)
            else:
              1'u32
          if src2 == src1 + run1 and dst2 == dst1 + run1 and (run1 + run2) <= 64:
            blk.fastOps[i].kind = fopCopyMultiYtoX
            blk.fastOps[i].dst = uint8(run1 + run2)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            continue

        # Copy Multi X to Y
        elif (
          blk.fastOps[i].kind == fopCopyXtoY or blk.fastOps[i].kind == fopCopyMultiXtoY
        ) and (
          blk.fastOps[j].kind == fopCopyXtoY or blk.fastOps[j].kind == fopCopyMultiXtoY
        ):
          let src1 = uint32(blk.fastOps[i].src1) or (uint32(blk.fastOps[i].src2) shl 8)
          let dst1 = blk.fastOps[i].imm
          let run1 =
            if blk.fastOps[i].kind == fopCopyMultiXtoY:
              uint32(blk.fastOps[i].dst)
            else:
              1'u32
          let src2 = uint32(blk.fastOps[j].src1) or (uint32(blk.fastOps[j].src2) shl 8)
          let dst2 = blk.fastOps[j].imm
          let run2 =
            if blk.fastOps[j].kind == fopCopyMultiXtoY:
              uint32(blk.fastOps[j].dst)
            else:
              1'u32
          if src2 == src1 + run1 and dst2 == dst1 + run1 and (run1 + run2) <= 64:
            blk.fastOps[i].kind = fopCopyMultiXtoY
            blk.fastOps[i].dst = uint8(run1 + run2)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            continue

        # Store Multi Imm Y
        elif (
          blk.fastOps[i].kind == fopStoreImmY or blk.fastOps[i].kind == fopStoreMultiImmY
        ) and (
          blk.fastOps[j].kind == fopStoreImmY or blk.fastOps[j].kind == fopStoreMultiImmY
        ) and blk.fastOps[i].imm == blk.fastOps[j].imm:
          let dst1 = uint32(blk.fastOps[i].src1) or (uint32(blk.fastOps[i].src2) shl 8)
          let run1 =
            if blk.fastOps[i].kind == fopStoreMultiImmY:
              uint32(blk.fastOps[i].dst)
            else:
              1'u32
          let dst2 = uint32(blk.fastOps[j].src1) or (uint32(blk.fastOps[j].src2) shl 8)
          let run2 =
            if blk.fastOps[j].kind == fopStoreMultiImmY:
              uint32(blk.fastOps[j].dst)
            else:
              1'u32
          if dst2 == dst1 + run1 and (run1 + run2) <= 64:
            blk.fastOps[i].kind = fopStoreMultiImmY
            blk.fastOps[i].dst = uint8(run1 + run2)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            continue

        # Store Multi Imm X
        elif (
          blk.fastOps[i].kind == fopStoreImmX or blk.fastOps[i].kind == fopStoreMultiImmX
        ) and (
          blk.fastOps[j].kind == fopStoreImmX or blk.fastOps[j].kind == fopStoreMultiImmX
        ) and blk.fastOps[i].imm == blk.fastOps[j].imm:
          let dst1 = uint32(blk.fastOps[i].src1) or (uint32(blk.fastOps[i].src2) shl 8)
          let run1 =
            if blk.fastOps[i].kind == fopStoreMultiImmX:
              uint32(blk.fastOps[i].dst)
            else:
              1'u32
          let dst2 = uint32(blk.fastOps[j].src1) or (uint32(blk.fastOps[j].src2) shl 8)
          let run2 =
            if blk.fastOps[j].kind == fopStoreMultiImmX:
              uint32(blk.fastOps[j].dst)
            else:
              1'u32
          if dst2 == dst1 + run1 and (run1 + run2) <= 64:
            blk.fastOps[i].kind = fopStoreMultiImmX
            blk.fastOps[i].dst = uint8(run1 + run2)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            continue

        # 30. Load Y Abs Reg -> Mpy Store Y
        elif blk.fastOps[i].kind == fopLoadYAbsReg and
            blk.fastOps[j].kind == fopMpyStoreY:
          let srcY = blk.fastOps[i].imm
          let dstY = blk.fastOps[j].imm
          if srcY < 65536 and dstY < 65536:
            blk.fastOps[i].kind = fopLoadYMpyStoreY
            blk.fastOps[i].dst = blk.fastOps[i].dst
            blk.fastOps[i].src1 = blk.fastOps[j].src1
            blk.fastOps[i].src2 = blk.fastOps[j].src2
            blk.fastOps[i].imm = srcY or (dstY shl 16)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 31. Load X Abs Reg -> Mpy Store Y
        elif blk.fastOps[i].kind == fopLoadXAbsReg and
            blk.fastOps[j].kind == fopMpyStoreY:
          let srcX = blk.fastOps[i].imm
          let dstY = blk.fastOps[j].imm
          if srcX < 65536 and dstY < 65536:
            blk.fastOps[i].kind = fopLoadXMpyStoreY
            blk.fastOps[i].dst = blk.fastOps[i].dst
            blk.fastOps[i].src1 = blk.fastOps[j].src1
            blk.fastOps[i].src2 = blk.fastOps[j].src2
            blk.fastOps[i].imm = srcX or (dstY shl 16)
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 32. Store Reg A1 -> Load Y Abs Add Reg
        elif blk.fastOps[i].kind == fopStoreRegA1 and
            blk.fastOps[j].kind == fopLoadYAbsAddReg:
          blk.fastOps[i].kind = fopStoreRegLoadAddY
          blk.fastOps[i].dst = blk.fastOps[i].dst
          blk.fastOps[i].src1 = blk.fastOps[j].src1
          blk.fastOps[i].imm = blk.fastOps[j].imm
          blk.fastOps[j].kind = fopNop
          passChanged = true
          i = j + 1
          continue

        # 33. Load Add Y Reg -> Store X Abs A1
        elif blk.fastOps[i].kind == fopLoadAddYReg and
            blk.fastOps[j].kind == fopStoreXAbsA1:
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopLoadAddStoreX
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 34. Load Y Abs Reg -> Store Y Abs Reg (Copy Y to Y)
        elif blk.fastOps[i].kind == fopLoadYAbsReg and
            blk.fastOps[j].kind == fopStoreYAbsReg and
            blk.fastOps[i].dst == blk.fastOps[j].src1:
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopCopyYtoY
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        # 35. Load X Abs Reg -> Store X Abs Reg (Copy X to X)
        elif blk.fastOps[i].kind == fopLoadXAbsReg and
            blk.fastOps[j].kind == fopStoreXAbsReg and
            blk.fastOps[i].dst == blk.fastOps[j].src1:
          let src = blk.fastOps[i].imm
          let dst = blk.fastOps[j].imm
          if src < 65536 and dst < 65536:
            blk.fastOps[i].kind = fopCopyXtoX
            blk.fastOps[i].src1 = uint8(src and 0xFF)
            blk.fastOps[i].src2 = uint8(src shr 8)
            blk.fastOps[i].imm = dst
            blk.fastOps[j].kind = fopNop
            passChanged = true
            i = j + 1
            continue

        inc i

  # Filter out fopNop so execution loop skips them completely
  var compacted = newSeqOfCap[FastOp](blk.fastOps.len)
  for f in blk.fastOps:
    if f.kind != fopNop:
      compacted.add(f)
  blk.fastOps = compacted
  blk.numFastOps = int32(blk.fastOps.len)
  blk.fastOpsArr =
    if blk.fastOps.len > 0:
      cast[ptr UncheckedArray[FastOp]](addr blk.fastOps[0])
    else:
      nil
