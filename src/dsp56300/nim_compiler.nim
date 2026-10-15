## `nim_compiler` - High-Level Idiomatic Nim AST Compiler for Motorola DSP56300/DSP56311
##
## Clean-room MIT implementation that translates high-level idiomatic Nim AST statements
## into 24-bit DSP56300 machine instruction words using `dsp56300/asm`.
##
## Supports:
##   - `while <cond>:` (including `while true:`)
##   - `if <cond>: ... elif <cond>: ... else: ...`
##   - Memory accesses: `xMem[addr]`, `yMem[addr]` (read & write)
##   - Arithmetic & Logic: `+`, `-`, `and`, `or`, `xor`, `shl`, `shr`, `asl`, `asr`, `mpy`, `mac`, `abs`
##   - Constant & Symbol Resolution
##   - Variable scoping & register allocation

import std/[macros, tables, strutils]
import dsp56300/decode_types
import "dsp56300/asm.nim"

# ---------------------------------------------------------------------------
# Target Mode 2 (Direct C11 / WASM / Native) Memory Buffer & Math Primitives
# ---------------------------------------------------------------------------

type
  DspMemSpace* = object
    data*: array[0x1000000, uint32]

var
  xMem* {.compileTime.}: DspMemSpace
  yMem* {.compileTime.}: DspMemSpace

proc `[]`*(m: DspMemSpace, address: uint32): uint32 {.inline, compileTime.} =
  m.data[address and 0x00FFFFFF'u32]

proc `[]=`*(m: var DspMemSpace, address: uint32, val: uint32) {.inline, compileTime.} =
  m.data[address and 0x00FFFFFF'u32] = val and 0x00FFFFFF'u32

proc `[]`*(m: DspMemSpace, address: int): uint32 {.inline, compileTime.} =
  m.data[uint32(address) and 0x00FFFFFF'u32]

proc `[]=`*(m: var DspMemSpace, address: int, val: uint32) {.inline, compileTime.} =
  m.data[uint32(address) and 0x00FFFFFF'u32] = val and 0x00FFFFFF'u32

func mpy*(a, b: uint32): uint32 {.inline, compileTime.} =
  ## 24-bit fractional signed multiplication: (a * b) >> 23
  let sa = if (a and 0x800000'u32) != 0: int64(a or 0xFF000000'u32) else: int64(a)
  let sb = if (b and 0x800000'u32) != 0: int64(b or 0xFF000000'u32) else: int64(b)
  let prod = (sa * sb) shr 23
  uint32(prod and 0x00FFFFFF'i64)

func mac*(a, b, acc: uint32): uint32 {.inline, compileTime.} =
  (acc + mpy(a, b)) and 0x00FFFFFF'u32

func asr*(a: uint32): uint32 {.inline, compileTime.} =
  let sign = a and 0x800000'u32
  sign or ((a and 0x7FFFFF'u32) shr 1)

func asl*(a: uint32): uint32 {.inline, compileTime.} =
  (a shl 1) and 0x00FFFFFF'u32

func abs24*(a: uint32): uint32 {.inline, compileTime.} =
  if (a and 0x800000'u32) != 0:
    ((not a) + 1'u32) and 0x00FFFFFF'u32
  else:
    a and 0x00FFFFFF'u32

# ---------------------------------------------------------------------------
# Two-Pass Kernel Assembler Builder
# ---------------------------------------------------------------------------

type
  KernelItemKind* = enum
    kiWord, kiWords2, kiLabel, kiBranch

  KernelItem* = object
    kind*: KernelItemKind
    word*: uint32
    words2*: array[2, uint32]
    labelName*: string
    isJmp*: bool
    cond*: ConditionCode
    targetLabel*: string

  KernelBuilder* = object
    items*: seq[KernelItem]

proc initKernelBuilder*(): KernelBuilder =
  result.items = @[]

proc addWord*(kb: var KernelBuilder, w: uint32) =
  kb.items.add(KernelItem(kind: kiWord, word: w))

proc addWords2*(kb: var KernelBuilder, ws: array[2, uint32]) =
  kb.items.add(KernelItem(kind: kiWords2, words2: ws))

proc addLabel*(kb: var KernelBuilder, name: string) =
  kb.items.add(KernelItem(kind: kiLabel, labelName: name))

proc addJmp*(kb: var KernelBuilder, target: string) =
  kb.items.add(KernelItem(kind: kiBranch, isJmp: true, targetLabel: target))

proc addJcc*(kb: var KernelBuilder, cond: ConditionCode, target: string) =
  kb.items.add(KernelItem(kind: kiBranch, isJmp: false, cond: cond, targetLabel: target))

proc build*(kb: KernelBuilder): seq[uint32] =
  # Pass 1: Resolve label addresses
  var labelMap = initTable[string, uint32]()
  var pc = 0'u32
  for item in kb.items:
    case item.kind
    of kiLabel:
      labelMap[item.labelName] = pc
    of kiWord:
      pc += 1
    of kiWords2:
      pc += 2
    of kiBranch:
      pc += 1

  # Pass 2: Emit binary words with resolved branch addresses
  result = @[]
  for item in kb.items:
    case item.kind
    of kiLabel:
      discard
    of kiWord:
      result.add(item.word)
    of kiWords2:
      result.add(item.words2[0])
      result.add(item.words2[1])
    of kiBranch:
      let targetPc = labelMap.getOrDefault(item.targetLabel, 0'u32)
      if item.isJmp:
        result.add(asmJmp(targetPc))
      else:
        result.add(asmJcc(item.cond, targetPc))

# ---------------------------------------------------------------------------
# AST Compiler Engine
# ---------------------------------------------------------------------------

type
  CompilerContext = object
    kb: KernelBuilder
    labelId: int
    varRegs: Table[string, RegId]
    varMem: Table[string, uint32]
    nextScratchAddr: uint32

proc genLabel(ctx: var CompilerContext, prefix: string): string =
  ctx.labelId += 1
  prefix & "_" & $ctx.labelId

proc resolveConstVal*(n: NimNode): (bool, uint32) =
  case n.kind
  of nnkIntLit..nnkUInt64Lit:
    return (true, uint32(n.intVal))
  of nnkIdent, nnkSym:
    let name = n.strVal
    case name
    of "ESAI_TX0_ADDR": return (true, 0xFFFFA0'u32)
    of "ESAI_RX0_ADDR": return (true, 0xFFFFA8'u32)
    of "HDI08_HSR_ADDR": return (true, 0xFFFFC3'u32)
    of "HDI08_HORX_ADDR": return (true, 0xFFFFC6'u32)
    of "HDI08_HOTX_ADDR": return (true, 0xFFFFC7'u32)
    of "X_PITCH_INC": return (true, 0x0010'u32)
    of "X_GATE": return (true, 0x0011'u32)
    of "X_WAVEFORM": return (true, 0x0012'u32)
    of "X_CUTOFF": return (true, 0x0013'u32)
    of "X_RESONANCE": return (true, 0x0014'u32)
    of "X_ATTACK": return (true, 0x0015'u32)
    of "X_RELEASE": return (true, 0x0016'u32)
    of "X_MASTER_LEVEL": return (true, 0x0017'u32)
    of "X_MODULE_GRAPH": return (true, 0x0018'u32)
    of "X_AUDIO_IN": return (true, 0x0020'u32)
    of "X_AUDIO_OUT": return (true, 0x0021'u32)
    of "Y_OSC_PHASE": return (true, 0x0010'u32)
    of "Y_ENV_LEVEL": return (true, 0x0011'u32)
    of "Y_FILT_LOW": return (true, 0x0012'u32)
    of "Y_FILT_BAND": return (true, 0x0013'u32)
    of "Y_PREV_SAMPLE": return (true, 0x0014'u32)
    of "CMD_NOP": return (true, 0x00'u32)
    of "CMD_NOTE_ON": return (true, 0x01'u32)
    of "CMD_NOTE_OFF": return (true, 0x02'u32)
    of "CMD_SET_CUTOFF": return (true, 0x03'u32)
    of "CMD_SET_RESONANCE": return (true, 0x04'u32)
    of "CMD_SET_WAVEFORM": return (true, 0x05'u32)
    of "CMD_SET_ATTACK": return (true, 0x06'u32)
    of "CMD_SET_RELEASE": return (true, 0x07'u32)
    of "CMD_SET_MASTER": return (true, 0x08'u32)
    of "CMD_WRITE_X": return (true, 0x10'u32)
    else:
      if n.kind == nnkSym:
        let impl = n.getImpl
        if impl.kind == nnkConstDef and impl[2].kind in {nnkIntLit..nnkUInt64Lit}:
          return (true, uint32(impl[2].intVal))
      return (false, 0'u32)
  of nnkInfix:
    let op = n[0].strVal
    let (okL, valL) = resolveConstVal(n[1])
    let (okR, valR) = resolveConstVal(n[2])
    if okL and okR:
      case op
      of "+": return (true, valL + valR)
      of "-": return (true, valL - valR)
      of "shl": return (true, valL shl valR)
      of "shr": return (true, valL shr valR)
      of "and": return (true, valL and valR)
      of "or": return (true, valL or valR)
      else: discard
    return (false, 0'u32)
  else:
    return (false, 0'u32)

proc compileExpr(ctx: var CompilerContext, n: NimNode, dstReg: RegId)

proc compileNode(ctx: var CompilerContext, n: NimNode)

proc compileCondition(ctx: var CompilerContext, condNode: NimNode, jumpIfFalseLabel: string) =
  ## Compiles boolean condition into conditional jump to `jumpIfFalseLabel` if condition evaluates to false.
  case condNode.kind
  of nnkInfix:
    let op = condNode[0].strVal
    let left = condNode[1]
    let right = condNode[2]

    # Special case: (expr and mask) != 0 or == 0
    if left.kind == nnkPar and left[0].kind == nnkInfix and left[0][0].strVal == "and":
      let innerExpr = left[0][1]
      let innerMask = left[0][2]
      compileExpr(ctx, innerExpr, RegId.regA)
      let (okM, maskVal) = resolveConstVal(innerMask)
      if okM:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, maskVal))
      else:
        compileExpr(ctx, innerMask, RegId.regX0)
      ctx.kb.addWord(asmAnd(RegId.regX0, RegId.regA))
      ctx.kb.addWord(asmTst(RegId.regA))
      if op == "!=":
        ctx.kb.addJcc(ConditionCode.ccEQ, jumpIfFalseLabel)
      else:
        ctx.kb.addJcc(ConditionCode.ccNE, jumpIfFalseLabel)
      return

    case op
    of "==":
      compileExpr(ctx, left, RegId.regA)
      let (okR, valR) = resolveConstVal(right)
      if okR:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
      else:
        compileExpr(ctx, right, RegId.regX0)
      ctx.kb.addWord(asmCmp(RegId.regX0, RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccNE, jumpIfFalseLabel)
    of "!=":
      compileExpr(ctx, left, RegId.regA)
      let (okR, valR) = resolveConstVal(right)
      if okR:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
      else:
        compileExpr(ctx, right, RegId.regX0)
      ctx.kb.addWord(asmCmp(RegId.regX0, RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccEQ, jumpIfFalseLabel)
    of "<":
      # If left < right, (left - right) < 0 (ccMI). Jump if false when ccPL.
      compileExpr(ctx, left, RegId.regA)
      let (okR, valR) = resolveConstVal(right)
      if okR:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
      else:
        compileExpr(ctx, right, RegId.regX0)
      ctx.kb.addWord(asmSub(RegId.regX0, RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccPL, jumpIfFalseLabel)
    of ">":
      # If left > right, (right - left) < 0 (ccMI). Jump if false when ccPL.
      compileExpr(ctx, right, RegId.regA)
      let (okL, valL) = resolveConstVal(left)
      if okL:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valL))
      else:
        compileExpr(ctx, left, RegId.regX0)
      ctx.kb.addWord(asmSub(RegId.regX0, RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccPL, jumpIfFalseLabel)
    of "<=":
      # Jump if false when left > right
      compileExpr(ctx, right, RegId.regA)
      let (okL, valL) = resolveConstVal(left)
      if okL:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valL))
      else:
        compileExpr(ctx, left, RegId.regX0)
      ctx.kb.addWord(asmSub(RegId.regX0, RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccMI, jumpIfFalseLabel)
    of ">=":
      # Jump if false when left < right
      compileExpr(ctx, left, RegId.regA)
      let (okR, valR) = resolveConstVal(right)
      if okR:
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
      else:
        compileExpr(ctx, right, RegId.regX0)
      ctx.kb.addWord(asmSub(RegId.regX0, RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccMI, jumpIfFalseLabel)
    else:
      compileExpr(ctx, condNode, RegId.regA)
      ctx.kb.addWord(asmTst(RegId.regA))
      ctx.kb.addJcc(ConditionCode.ccEQ, jumpIfFalseLabel)
  of nnkPar:
    compileCondition(ctx, condNode[0], jumpIfFalseLabel)
  else:
    compileExpr(ctx, condNode, RegId.regA)
    ctx.kb.addWord(asmTst(RegId.regA))
    ctx.kb.addJcc(ConditionCode.ccEQ, jumpIfFalseLabel)

proc compileExpr(ctx: var CompilerContext, n: NimNode, dstReg: RegId) =
  case n.kind
  of nnkIntLit..nnkUInt64Lit:
    let val = uint32(n.intVal)
    if val == 0:
      ctx.kb.addWord(asmClr(dstReg))
    elif val <= 0xFF:
      ctx.kb.addWord(asmMoveImmShort(dstReg, uint8(val)))
    else:
      ctx.kb.addWords2(asmMoveImm24(dstReg, val))
  of nnkIdent, nnkSym:
    let name = n.strVal
    let (isConst, val) = resolveConstVal(n)
    if isConst:
      if val == 0:
        ctx.kb.addWord(asmClr(dstReg))
      elif val <= 0xFF:
        ctx.kb.addWord(asmMoveImmShort(dstReg, uint8(val)))
      else:
        ctx.kb.addWords2(asmMoveImm24(dstReg, val))
    elif ctx.varRegs.hasKey(name):
      let src = ctx.varRegs[name]
      if src != dstReg:
        ctx.kb.addWord(asmMoveReg(src, dstReg))
    elif ctx.varMem.hasKey(name):
      let addr16 = ctx.varMem[name]
      ctx.kb.addWords2(asmMoveMemAbs(MemSpace.memY, isWrite = false, reg = dstReg, addr16 = addr16))
    else:
      # Default fallback: check if register name
      case name.toLowerAscii()
      of "a": ctx.kb.addWord(asmMoveReg(RegId.regA, dstReg))
      of "b": ctx.kb.addWord(asmMoveReg(RegId.regB, dstReg))
      of "x0": ctx.kb.addWord(asmMoveReg(RegId.regX0, dstReg))
      of "x1": ctx.kb.addWord(asmMoveReg(RegId.regX1, dstReg))
      of "y0": ctx.kb.addWord(asmMoveReg(RegId.regY0, dstReg))
      of "y1": ctx.kb.addWord(asmMoveReg(RegId.regY1, dstReg))
      else: discard

  of nnkBracketExpr:
    # xMem[addr] or yMem[addr]
    let memName = n[0].strVal
    let addrNode = n[1]
    let isY = (memName == "yMem")
    let space = if isY: MemSpace.memY else: MemSpace.memX
    let (isConstAddr, addrVal) = resolveConstVal(addrNode)

    if isConstAddr:
      ctx.kb.addWords2(asmMoveMemAbs(space, isWrite = false, reg = dstReg, addr16 = addrVal))
    else:
      # Evaluate address into A, move to R0
      compileExpr(ctx, addrNode, RegId.regA)
      ctx.kb.addWord(asmMoveReg(RegId.regA, RegId.regR0))
      ctx.kb.addWord(asmMoveMemInd(space, isWrite = false, reg = dstReg, rNum = 0))

  of nnkInfix:
    let op = n[0].strVal
    let left = n[1]
    let right = n[2]
    case op
    of "+":
      let (okR, valR) = resolveConstVal(right)
      if okR:
        compileExpr(ctx, left, dstReg)
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
        ctx.kb.addWord(asmAdd(RegId.regX0, dstReg))
      else:
        compileExpr(ctx, left, RegId.regX0)
        compileExpr(ctx, right, dstReg)
        ctx.kb.addWord(asmAdd(RegId.regX0, dstReg))
    of "-":
      let (okR, valR) = resolveConstVal(right)
      if okR:
        compileExpr(ctx, left, RegId.regB)
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
        ctx.kb.addWord(asmSub(RegId.regX0, RegId.regB))
        if dstReg != RegId.regB:
          ctx.kb.addWord(asmMoveReg(RegId.regB, dstReg))
      else:
        compileExpr(ctx, right, RegId.regX0)
        compileExpr(ctx, left, RegId.regB)
        ctx.kb.addWord(asmSub(RegId.regX0, RegId.regB))
        if dstReg != RegId.regB:
          ctx.kb.addWord(asmMoveReg(RegId.regB, dstReg))
    of "*":
      compileExpr(ctx, left, RegId.regX0)
      compileExpr(ctx, right, RegId.regY0)
      ctx.kb.addWord(asmMpy(RegId.regX0, RegId.regY0, dstReg))
    of "and":
      let (okR, valR) = resolveConstVal(right)
      if okR:
        compileExpr(ctx, left, dstReg)
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
        ctx.kb.addWord(asmAnd(RegId.regX0, dstReg))
      else:
        compileExpr(ctx, left, RegId.regB)
        compileExpr(ctx, right, RegId.regX0)
        ctx.kb.addWord(asmAnd(RegId.regX0, RegId.regB))
        if dstReg != RegId.regB:
          ctx.kb.addWord(asmMoveReg(RegId.regB, dstReg))
    of "or":
      let (okR, valR) = resolveConstVal(right)
      if okR:
        compileExpr(ctx, left, dstReg)
        ctx.kb.addWords2(asmMoveImm24(RegId.regX0, valR))
        ctx.kb.addWord(asmOr(RegId.regX0, dstReg))
      else:
        compileExpr(ctx, left, RegId.regB)
        compileExpr(ctx, right, RegId.regX0)
        ctx.kb.addWord(asmOr(RegId.regX0, RegId.regB))
        if dstReg != RegId.regB:
          ctx.kb.addWord(asmMoveReg(RegId.regB, dstReg))
    of "shl":
      let (okR, valR) = resolveConstVal(right)
      compileExpr(ctx, left, dstReg)
      let shifts = if okR: int(valR) else: 1
      for _ in 0 ..< shifts:
        ctx.kb.addWord(asmAsl(dstReg))
    of "shr":
      let (okR, valR) = resolveConstVal(right)
      compileExpr(ctx, left, dstReg)
      let shifts = if okR: int(valR) else: 1
      for _ in 0 ..< shifts:
        ctx.kb.addWord(asmAsr(dstReg))
    else:
      discard

  of nnkCall:
    let fn = n[0].strVal
    case fn
    of "mpy":
      compileExpr(ctx, n[1], RegId.regX0)
      compileExpr(ctx, n[2], RegId.regY0)
      ctx.kb.addWord(asmMpy(RegId.regX0, RegId.regY0, dstReg))
    of "mac":
      compileExpr(ctx, n[3], dstReg)
      compileExpr(ctx, n[1], RegId.regX0)
      compileExpr(ctx, n[2], RegId.regY0)
      ctx.kb.addWord(asmMac(RegId.regX0, RegId.regY0, dstReg))
    of "abs", "abs24":
      compileExpr(ctx, n[1], dstReg)
      ctx.kb.addWord(asmAbs(dstReg))
    of "asl":
      compileExpr(ctx, n[1], dstReg)
      ctx.kb.addWord(asmAsl(dstReg))
    of "asr":
      compileExpr(ctx, n[1], dstReg)
      ctx.kb.addWord(asmAsr(dstReg))
    else:
      discard

  of nnkPar:
    compileExpr(ctx, n[0], dstReg)
  else:
    discard

proc compileNode(ctx: var CompilerContext, n: NimNode) =
  case n.kind
  of nnkStmtList:
    for child in n:
      compileNode(ctx, child)

  of nnkWhileStmt:
    let cond = n[0]
    let body = n[1]
    let startLabel = genLabel(ctx, "while_start")
    let endLabel = genLabel(ctx, "while_end")

    ctx.kb.addLabel(startLabel)
    if cond.kind == nnkIdent and cond.strVal == "true":
      compileNode(ctx, body)
      ctx.kb.addJmp(startLabel)
    else:
      compileCondition(ctx, cond, endLabel)
      compileNode(ctx, body)
      ctx.kb.addJmp(startLabel)
    ctx.kb.addLabel(endLabel)

  of nnkIfStmt:
    let endLabel = genLabel(ctx, "if_end")
    for branch in n:
      if branch.kind == nnkElifBranch:
        let nextBranchLabel = genLabel(ctx, "elif_next")
        compileCondition(ctx, branch[0], nextBranchLabel)
        compileNode(ctx, branch[1])
        ctx.kb.addJmp(endLabel)
        ctx.kb.addLabel(nextBranchLabel)
      elif branch.kind == nnkElse:
        compileNode(ctx, branch[0])
    ctx.kb.addLabel(endLabel)

  of nnkAsgn:
    let target = n[0]
    let expr = n[1]

    if target.kind == nnkBracketExpr:
      let memName = target[0].strVal
      let addrNode = target[1]
      let isY = (memName == "yMem")
      let space = if isY: MemSpace.memY else: MemSpace.memX
      let (isConstAddr, addrVal) = resolveConstVal(addrNode)

      if isConstAddr:
        compileExpr(ctx, expr, RegId.regA)
        ctx.kb.addWords2(asmMoveMemAbs(space, isWrite = true, reg = RegId.regA, addr16 = addrVal))
      else:
        # Complex address
        compileExpr(ctx, expr, RegId.regX1)
        compileExpr(ctx, addrNode, RegId.regA)
        ctx.kb.addWord(asmMoveReg(RegId.regA, RegId.regR0))
        ctx.kb.addWord(asmMoveReg(RegId.regX1, RegId.regA))
        ctx.kb.addWord(asmMoveMemInd(space, isWrite = true, reg = RegId.regA, rNum = 0))

    elif target.kind in {nnkIdent, nnkSym}:
      let varName = target.strVal
      if ctx.varRegs.hasKey(varName):
        let reg = ctx.varRegs[varName]
        compileExpr(ctx, expr, reg)
      elif ctx.varMem.hasKey(varName):
        let addr16 = ctx.varMem[varName]
        compileExpr(ctx, expr, RegId.regA)
        ctx.kb.addWords2(asmMoveMemAbs(MemSpace.memY, isWrite = true, reg = RegId.regA, addr16 = addr16))

  of nnkLetSection, nnkVarSection:
    for identDefs in n:
      let varName = identDefs[0].strVal
      let expr = identDefs[2]

      # Assign available physical register or scratch memory address
      let assignedReg = case ctx.varRegs.len
      of 0: RegId.regX1
      of 1: RegId.regY1
      of 2: RegId.regB
      else: RegId.regNone

      if assignedReg != RegId.regNone:
        ctx.varRegs[varName] = assignedReg
        if expr.kind != nnkEmpty:
          compileExpr(ctx, expr, assignedReg)
      else:
        ctx.varMem[varName] = ctx.nextScratchAddr
        ctx.nextScratchAddr += 1
        if expr.kind != nnkEmpty:
          compileExpr(ctx, expr, RegId.regA)
          ctx.kb.addWords2(asmMoveMemAbs(MemSpace.memY, isWrite = true, reg = RegId.regA, addr16 = ctx.varMem[varName]))

  else:
    discard

proc assembleFromAst*(body: NimNode): seq[uint32] =
  var ctx: CompilerContext
  ctx.kb = initKernelBuilder()
  ctx.labelId = 0
  ctx.varRegs = initTable[string, RegId]()
  ctx.varMem = initTable[string, uint32]()
  ctx.nextScratchAddr = 0x0030'u32

  compileNode(ctx, body)
  result = ctx.kb.build()

macro compileDsp56300*(body: untyped): untyped =
  let words = assembleFromAst(body)
  result = newNimNode(nnkPrefix)
  result.add(ident("@"))
  var bracket = newNimNode(nnkBracket)
  for w in words:
    bracket.add(newLit(w))
  result.add(bracket)
