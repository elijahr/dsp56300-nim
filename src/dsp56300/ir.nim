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

  IrBasicBlock* = object
    startPc*: uint32
    endPc*: uint32
    generation*: uint32
    ops*: seq[MicroOp]
    isHot*: bool
    execCount*: uint64

  DspState* = object
    core*: Dsp56300State
    mem*: Dsp56300Memory
    pRamGen*: seq[uint32]

proc newDspState*(pRamWords: int = P_RAM_MAX_WORDS): DspState =
  result.core.reset()
  result.mem = initMemory()
  result.pRamGen = newSeq[uint32](pRamWords)
  for i in 0..<pRamWords:
    result.pRamGen[i] = 1'u32

# Ergonomic Accessors forward to core & mem
template pc*(s: DspState): uint32 = s.core.pc
template `pc=`*(s: var DspState, v: uint32) = s.core.pc = v

template sr*(s: DspState): uint32 = s.core.sr
template `sr=`*(s: var DspState, v: uint32) = s.core.sr = v

template x0*(s: DspState): uint32 = s.core.x0
template `x0=`*(s: var DspState, v: uint32) = s.core.x0 = v

template x1*(s: DspState): uint32 = s.core.x1
template `x1=`*(s: var DspState, v: uint32) = s.core.x1 = v

template y0*(s: DspState): uint32 = s.core.y0
template `y0=`*(s: var DspState, v: uint32) = s.core.y0 = v

template y1*(s: DspState): uint32 = s.core.y1
template `y1=`*(s: var DspState, v: uint32) = s.core.y1 = v

template a2*(s: DspState): uint8 = s.core.a2
template `a2=`*(s: var DspState, v: uint8) = s.core.a2 = v

template a1*(s: DspState): uint32 = s.core.a1
template `a1=`*(s: var DspState, v: uint32) = s.core.a1 = v

template a0*(s: DspState): uint32 = s.core.a0
template `a0=`*(s: var DspState, v: uint32) = s.core.a0 = v

template b2*(s: DspState): uint8 = s.core.b2
template `b2=`*(s: var DspState, v: uint8) = s.core.b2 = v

template b1*(s: DspState): uint32 = s.core.b1
template `b1=`*(s: var DspState, v: uint32) = s.core.b1 = v

template b0*(s: DspState): uint32 = s.core.b0
template `b0=`*(s: var DspState, v: uint32) = s.core.b0 = v

template r*(s: DspState): untyped = s.core.r
template n*(s: DspState): untyped = s.core.n
template m*(s: DspState): untyped = s.core.m

template pRam*(s: DspState): untyped = s.mem.pRam
template xRam*(s: DspState): untyped = s.mem.xRam
template yRam*(s: DspState): untyped = s.mem.yRam

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
  for op in blk.ops:
    if op.kind == IrOpKind.irCheckGen:
      let addrIdx = int(op.pAddr)
      if addrIdx < state.pRamGen.len:
        if state.pRamGen[addrIdx] != op.expectedGen:
          return false
  return true

proc liftBasicBlock*(state: DspState, startPc: uint32, maxWords: int = 64): IrBasicBlock =
  result.startPc = startPc
  result.generation = if int(startPc) < state.pRamGen.len: state.pRamGen[int(startPc)] else: 1'u32
  result.ops = @[]

  var curPc = startPc
  var wordsRead = 0

  while wordsRead < maxWords and int(curPc) < state.mem.pRam.len:
    let w0 = state.mem.pRam[int(curPc)]
    let w1 = if int(curPc + 1) < state.mem.pRam.len: state.mem.pRam[int(curPc + 1)] else: 0'u32
    let gen = if int(curPc) < state.pRamGen.len: state.pRamGen[int(curPc)] else: 1'u32

    # Check generation counter for self-modifying code invalidation
    result.ops.add(MicroOp(kind: IrOpKind.irCheckGen, pAddr: curPc, expectedGen: gen))

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
      of ControlOp.ctrlJmp:
        result.ops.add(MicroOp(kind: IrOpKind.irBranch, imm: inst.targetAddr, pAddr: curPc))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlJcc:
        result.ops.add(MicroOp(kind: IrOpKind.irBranchCond, imm: inst.targetAddr, cond: inst.cond, pAddr: curPc))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlJscc:
        result.ops.add(MicroOp(kind: IrOpKind.irCall, imm: inst.targetAddr, cond: inst.cond, pAddr: curPc))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlBra:
        result.ops.add(MicroOp(kind: IrOpKind.irBranch, imm: inst.targetAddr, pAddr: curPc))
        curPc += uint32(instWords)
        wordsRead += instWords
        break
      of ControlOp.ctrlDo:
        result.ops.add(MicroOp(kind: IrOpKind.irLoopDo, imm: inst.immValue, pAddr: inst.targetAddr))
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
      else: discard

    # If instruction has a parallel move, emit micro-ops
    case inst.parallel.kind
    of ParallelMoveKind.pmNone:
      discard
    of ParallelMoveKind.pmImmediateShort:
      result.ops.add(MicroOp(
        kind: IrOpKind.irLoadImm,
        dst: inst.parallel.immDst,
        imm: inst.parallel.immShort
      ))
    of ParallelMoveKind.pmRegToReg:
      result.ops.add(MicroOp(
        kind: IrOpKind.irLoadReg,
        dst: inst.parallel.regDst,
        src1: inst.parallel.regSrc
      ))
    of ParallelMoveKind.pmAddrUpdate:
      result.ops.add(MicroOp(
        kind: IrOpKind.irAguUpdate,
        rNum: inst.parallel.uReg,
        addrMode: inst.parallel.uMode
      ))
    of ParallelMoveKind.pmXMem, ParallelMoveKind.pmYMem:
      if not inst.parallel.isWrite:
        result.ops.add(MicroOp(
          kind: IrOpKind.irLoadMem,
          dst: inst.parallel.memReg,
          space: inst.parallel.memSpace,
          addrMode: inst.parallel.memMode,
          rNum: inst.parallel.memRNum,
          imm: inst.parallel.memAddr
        ))
      else:
        result.ops.add(MicroOp(
          kind: IrOpKind.irStoreMem,
          src1: inst.parallel.memReg,
          space: inst.parallel.memSpace,
          addrMode: inst.parallel.memMode,
          rNum: inst.parallel.memRNum,
          imm: inst.parallel.memAddr
        ))
      if inst.parallel.memMode in {AddrMode.amPostInc, AddrMode.amPostDec, AddrMode.amPostIncN, AddrMode.amPostDecN}:
        result.ops.add(MicroOp(
          kind: IrOpKind.irAguUpdate,
          rNum: inst.parallel.memRNum,
          addrMode: inst.parallel.memMode
        ))
    of ParallelMoveKind.pmXYDual:
      # Dual Move: reads observe pre-ALU values!
      if not inst.parallel.xWrite:
        result.ops.add(MicroOp(
          kind: IrOpKind.irLoadMem,
          dst: inst.parallel.xReg,
          space: MemSpace.memX,
          addrMode: inst.parallel.xMode,
          rNum: inst.parallel.xRNum
        ))
      else:
        result.ops.add(MicroOp(
          kind: IrOpKind.irStoreMem,
          src1: inst.parallel.xReg,
          space: MemSpace.memX,
          addrMode: inst.parallel.xMode,
          rNum: inst.parallel.xRNum
        ))

      if not inst.parallel.yWrite:
        result.ops.add(MicroOp(
          kind: IrOpKind.irLoadMem,
          dst: inst.parallel.yReg,
          space: MemSpace.memY,
          addrMode: inst.parallel.yMode,
          rNum: inst.parallel.yRNum
        ))
      else:
        result.ops.add(MicroOp(
          kind: IrOpKind.irStoreMem,
          src1: inst.parallel.yReg,
          space: MemSpace.memY,
          addrMode: inst.parallel.yMode,
          rNum: inst.parallel.yRNum
        ))

      # AGU post updates for both X and Y
      result.ops.add(MicroOp(
        kind: IrOpKind.irAguUpdate,
        rNum: inst.parallel.xRNum,
        addrMode: inst.parallel.xMode
      ))
      result.ops.add(MicroOp(
        kind: IrOpKind.irAguUpdate,
        rNum: inst.parallel.yRNum,
        addrMode: inst.parallel.yMode
      ))
    of ParallelMoveKind.pmIfCc:
      discard # Handled in ALU conditional execution
    else: discard

    # Emit ALU Micro-Op
    if inst.aluOp != AluOp.opNop and inst.aluOp != AluOp.opMove:
      var op = MicroOp(
        kind: IrOpKind.irAluOp,
        aluOp: inst.aluOp,
        dst: inst.dstReg,
        src1: inst.src1Reg,
        src2: inst.src2Reg,
        isRounded: inst.isRounded,
        isNeg: inst.isNegMpy
      )
      if inst.parallel.kind == ParallelMoveKind.pmIfCc:
        op.cond = inst.parallel.cc
        op.updateCcr = inst.parallel.updateCcr
      result.ops.add(op)

    curPc += uint32(instWords)
    wordsRead += instWords

  result.endPc = curPc
