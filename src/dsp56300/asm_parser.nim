## Clean-room MIT Motorola DSP56300 Assembly Text Parser & File Assembler
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import std/[strutils, tables, parseutils]
import dsp56300/decode_types
import "dsp56300/asm.nim"

type
  AsmEntry* = object
    address*: uint32
    word*: uint32

  AsmResult* = object
    pRam*: seq[AsmEntry]
    xRam*: seq[AsmEntry]
    yRam*: seq[AsmEntry]
    symbols*: Table[string, uint32]
    binaryWords*: seq[uint32]

# ------------------------------------------------------------- Register Helpers

func parseRegId*(token: string): (bool, RegId) =
  let t = token.strip().toUpperAscii()
  case t
  of "X0": (true, RegId.regX0)
  of "X1": (true, RegId.regX1)
  of "Y0": (true, RegId.regY0)
  of "Y1": (true, RegId.regY1)
  of "A0": (true, RegId.regA0)
  of "A1": (true, RegId.regA1)
  of "A2": (true, RegId.regA2)
  of "A":  (true, RegId.regA)
  of "B0": (true, RegId.regB0)
  of "B1": (true, RegId.regB1)
  of "B2": (true, RegId.regB2)
  of "B":  (true, RegId.regB)
  of "R0": (true, RegId.regR0)
  of "R1": (true, RegId.regR1)
  of "R2": (true, RegId.regR2)
  of "R3": (true, RegId.regR3)
  of "R4": (true, RegId.regR4)
  of "R5": (true, RegId.regR5)
  of "R6": (true, RegId.regR6)
  of "R7": (true, RegId.regR7)
  of "N0": (true, RegId.regN0)
  of "N1": (true, RegId.regN1)
  of "N2": (true, RegId.regN2)
  of "N3": (true, RegId.regN3)
  of "N4": (true, RegId.regN4)
  of "N5": (true, RegId.regN5)
  of "N6": (true, RegId.regN6)
  of "N7": (true, RegId.regN7)
  of "M0": (true, RegId.regM0)
  of "M1": (true, RegId.regM1)
  of "M2": (true, RegId.regM2)
  of "M3": (true, RegId.regM3)
  of "M4": (true, RegId.regM4)
  of "M5": (true, RegId.regM5)
  of "M6": (true, RegId.regM6)
  of "M7": (true, RegId.regM7)
  of "SR":  (true, RegId.regSR)
  of "OMR": (true, RegId.regOMR)
  of "SP":  (true, RegId.regSP)
  of "SSH": (true, RegId.regSSH)
  of "SSL": (true, RegId.regSSL)
  of "LA":  (true, RegId.regLA)
  of "LC":  (true, RegId.regLC)
  of "EP":  (true, RegId.regEP)
  of "VBA": (true, RegId.regVBA)
  of "SC":  (true, RegId.regSC)
  of "SZ":  (true, RegId.regSZ)
  else: (false, RegId.regNone)

func parseConditionCode*(token: string): (bool, ConditionCode) =
  let t = token.strip().toUpperAscii()
  case t
  of "EQ", "CCEQ", "JEQ": (true, ConditionCode.ccEQ)
  of "NE", "CCNE", "JNE": (true, ConditionCode.ccNE)
  of "CS", "CCCS", "JCS", "LO", "CCLO", "JLO": (true, ConditionCode.ccLO)
  of "CC", "CCCC", "JCC", "HS", "CCHS", "JHS": (true, ConditionCode.ccHS)
  of "MI", "CCMI", "JMI": (true, ConditionCode.ccMI)
  of "PL", "CCPL", "JPL": (true, ConditionCode.ccPL)
  of "GE", "CCGE", "JGE": (true, ConditionCode.ccGE)
  of "LT", "CCLT", "JLT": (true, ConditionCode.ccLT)
  of "GT", "CCGT", "JGT": (true, ConditionCode.ccGT)
  of "LE", "CCLE", "JLE": (true, ConditionCode.ccLE)
  of "LC", "CCLC", "JLC": (true, ConditionCode.ccLC)
  of "LS", "CCLS", "JLS": (true, ConditionCode.ccLS)
  of "EC", "CCEC", "JEC": (true, ConditionCode.ccEC)
  of "ES", "CCES", "JES": (true, ConditionCode.ccES)
  of "NN", "CCNN", "JNN": (true, ConditionCode.ccNN)
  of "NR", "CCNR", "JNR": (true, ConditionCode.ccNR)
  else: (false, ConditionCode.ccEQ)

# ------------------------------------------------------------- Literal Parsing

proc parseNumberLit*(token: string, symbols: Table[string, uint32]): uint32 =
  var t = token.strip()
  if t.startsWith("#"):
    t = t[1..^1].strip()
  
  if t in symbols:
    return symbols[t]

  var isNeg = false
  if t.startsWith("-"):
    isNeg = true
    t = t[1..^1].strip()

  var val: uint32 = 0
  if t.startsWith("$"):
    var hexVal = 0
    discard parseHex(t[1..^1], hexVal)
    val = uint32(hexVal)
  elif t.startsWith("0x") or t.startsWith("0X"):
    var hexVal = 0
    discard parseHex(t[2..^1], hexVal)
    val = uint32(hexVal)
  elif t.startsWith("%"):
    var binVal = 0
    discard parseBin(t[1..^1], binVal)
    val = uint32(binVal)
  else:
    var intVal = 0
    if parseInt(t, intVal) > 0:
      val = uint32(intVal)
    elif t in symbols:
      val = symbols[t]
    else:
      raise newException(ValueError, "Unknown symbol or invalid literal: '" & token & "'")

  if isNeg:
    let signedVal = -int32(val)
    val = uint32(signedVal and 0x00FFFFFF)
  return val and 0x00FFFFFF'u32

# ------------------------------------------------------------- Memory Operand Parsing

type
  MemOpKind* = enum
    mopNone, mopAbsolute, mopIndirect

  MemOperand* = object
    space*: MemSpace
    kind*: MemOpKind
    address*: uint32
    rNum*: uint8
    mode*: AddrMode

proc parseMemOperand*(token: string, symbols: Table[string, uint32]): MemOperand =
  var t = token.strip()
  var space = MemSpace.memX
  if t.startsWith("X:") or t.startsWith("x:"):
    space = MemSpace.memX
    t = t[2..^1].strip()
  elif t.startsWith("Y:") or t.startsWith("y:"):
    space = MemSpace.memY
    t = t[2..^1].strip()
  elif t.startsWith("P:") or t.startsWith("p:"):
    space = MemSpace.memP
    t = t[2..^1].strip()
  else:
    return MemOperand(kind: mopNone)

  # Check indirect (Rn)...
  if t.startsWith("(") or t.startsWith("-("):
    var isPreDec = false
    if t.startsWith("-"):
      isPreDec = true
      t = t[1..^1]
    
    let closeIdx = t.find(')')
    if closeIdx < 0:
      return MemOperand(kind: mopNone)
    
    let rToken = t[1..<closeIdx].strip().toUpperAscii()
    if not rToken.startsWith("R") or rToken.len != 2:
      return MemOperand(kind: mopNone)
    let rNum = uint8(ord(rToken[1]) - ord('0'))
    if rNum > 7:
      return MemOperand(kind: mopNone)

    let postFix = t[(closeIdx + 1)..^1].strip().toUpperAscii()
    var mode = AddrMode.amNoUpdate
    if isPreDec:
      mode = AddrMode.amPreDec
    elif postFix == "+":
      mode = AddrMode.amPostInc
    elif postFix == "-":
      mode = AddrMode.amPostDec
    elif postFix.startsWith("+N"):
      mode = AddrMode.amPostIncN
    elif postFix.startsWith("-N"):
      mode = AddrMode.amPostDecN
    elif postFix == "":
      mode = AddrMode.amNoUpdate

    return MemOperand(space: space, kind: mopIndirect, rNum: rNum, mode: mode)
  else:
    # Absolute address / symbol
    let addrVal = parseNumberLit(t, symbols)
    return MemOperand(space: space, kind: mopAbsolute, address: addrVal)

# ------------------------------------------------------------- Assembler Engine

proc assembleText*(text: string, baseOrg: uint32 = 0): AsmResult =
  var lines = text.splitLines()
  var symbols = initTable[string, uint32]()
  var curSpace = MemSpace.memP
  var pcP: uint32 = baseOrg
  var pcX: uint32 = 0
  var pcY: uint32 = 0

  template getPc(): uint32 =
    case curSpace
    of MemSpace.memP: pcP
    of MemSpace.memX: pcX
    of MemSpace.memY: pcY
    else: pcP

  template advancePc(delta: uint32 = 1) =
    case curSpace
    of MemSpace.memP: pcP += delta
    of MemSpace.memX: pcX += delta
    of MemSpace.memY: pcY += delta
    else: pcP += delta

  # ----------------------------------------------------------- Pass 1: Symbol Definition
  # ----------------------------------------------------------- Pass 1: Label Collection & Sizing
  for iter in 0 .. 1:
    curSpace = MemSpace.memP
    pcP = baseOrg
    pcX = 0
    pcY = 0

    for rawLine in lines:
      var line = rawLine
      # Strip comments (; or // or #)
      let cIdx = line.find(';')
      if cIdx >= 0: line = line[0..<cIdx]
      let c2Idx = line.find("//")
      if c2Idx >= 0: line = line[0..<c2Idx]
      line = line.strip()
      if line.len == 0: continue

      # Check EQU: "label EQU $0010" or "label: EQU $0010"
      let parts = line.splitWhitespace()
      if parts.len >= 3 and parts[1].toUpperAscii() == "EQU":
        let sym = parts[0].strip(chars = {':'})
        let val = parseNumberLit(parts[2], symbols)
        symbols[sym] = val
        continue

      # Check ORG: "ORG P:$100"
      if parts[0].toUpperAscii() == "ORG" and parts.len >= 2:
        let target = parts[1].strip()
        if target.startsWith("P:") or target.startsWith("p:"):
          curSpace = MemSpace.memP
          pcP = parseNumberLit(target[2..^1], symbols)
        elif target.startsWith("X:") or target.startsWith("x:"):
          curSpace = MemSpace.memX
          pcX = parseNumberLit(target[2..^1], symbols)
        elif target.startsWith("Y:") or target.startsWith("y:"):
          curSpace = MemSpace.memY
          pcY = parseNumberLit(target[2..^1], symbols)
        continue

      var codeLine = line
      # Check if starts with a label: e.g. "loop_top:" or "loop_top"
      var label = ""
      if not (parts[0].toUpperAscii() in [
        "NOP", "RTS", "RTI", "RESET", "WAIT", "STOP", "ENDDO", "JMP", "JSR", "JCC",
        "JEQ", "JNE", "JCS", "JHS", "JLO", "JMI", "JPL", "JGE", "JLT", "JGT", "JLE", "JLC", "JLS", "JEC", "JES", "JNN", "JNR",
        "CLR", "ADD", "SUB", "CMP", "AND", "OR", "EOR", "NOT", "MPY", "MAC", "MACR",
        "ASL", "ASR", "LSR", "NEG", "ABS", "TFR", "TST", "RND", "DO", "REP", "MOVE", "DC", "DS"
      ]):
        if parts[0].endsWith(":"):
          label = parts[0][0..^2]
          codeLine = line[parts[0].len..^1].strip()
        elif parts.len == 1:
          label = parts[0]
          codeLine = ""
        else:
          label = parts[0]
          codeLine = line[parts[0].len..^1].strip()

        if label.len > 0:
          symbols[label] = getPc()

      if codeLine.len == 0:
        continue

      # Estimate instruction size for PC advance
      let cparts = codeLine.splitWhitespace()
      let mnem = cparts[0].toUpperAscii()
      case mnem
      of "DO":
        advancePc(2)
      of "DC", "DC.W":
        let args = codeLine[mnem.len..^1].split(',')
        advancePc(uint32(args.len))
      of "DS":
        let cnt = parseNumberLit(cparts[1], symbols)
        advancePc(cnt)
      of "MOVE":
        # Move short vs move 24 vs move mem abs vs move mem ind
        let rest = codeLine[mnem.len..^1].strip()
        let ops = rest.split(',')
        if ops.len >= 2:
          let s = ops[0].strip()
          let d = ops[1].strip()
          let (isSrcReg, _) = parseRegId(s)
          let (isDstReg, _) = parseRegId(d)
          if s.startsWith("#"):
            let imm = parseNumberLit(s, symbols)
            let sRaw = s.strip()
            let isExplicit24 = (sRaw.startsWith("#$") or sRaw.startsWith("#0x") or sRaw.startsWith("#0X")) and sRaw.len > 5
            if imm > 0xFF'u32 or isExplicit24:
              advancePc(2)
            else:
              advancePc(1)
          elif (s.startsWith("X:") or s.startsWith("Y:")) and not s.contains("("):
            advancePc(2)
          elif (d.startsWith("X:") or d.startsWith("Y:")) and not d.contains("("):
            advancePc(2)
          else:
            advancePc(1)
        else:
          advancePc(1)
      of "JMP", "JSR", "JCC",
         "JEQ", "JNE", "JCS", "JHS", "JLO", "JMI", "JPL",
         "JGE", "JLT", "JGT", "JLE", "JLC", "JLS", "JEC", "JES", "JNN", "JNR":
        let rest = if codeLine.len > cparts[0].len: codeLine[cparts[0].len..^1].strip() else: ""
        var targetStr = rest
        if mnem == "JCC":
          let ops = rest.split(',')
          if ops.len >= 2: targetStr = ops[1].strip()
        if symbols.hasKey(targetStr):
          if symbols[targetStr] >= 0x1000'u32:
            advancePc(2)
          else:
            advancePc(1)
        else:
          var isLong = false
          if getPc() >= 0x0FC0'u32:
            isLong = true
          else:
            try:
              let lit = parseNumberLit(targetStr, symbols)
              if lit >= 0x1000'u32: isLong = true
            except:
              discard
          if isLong:
            advancePc(2)
          else:
            advancePc(1)
      else:
        advancePc(1)

  # ----------------------------------------------------------- Pass 2: Encoding
  result.symbols = symbols
  curSpace = MemSpace.memP
  pcP = baseOrg
  pcX = 0
  pcY = 0

  for rawLine in lines:
    var line = rawLine
    let cIdx = line.find(';')
    if cIdx >= 0: line = line[0..<cIdx]
    let c2Idx = line.find("//")
    if c2Idx >= 0: line = line[0..<c2Idx]
    line = line.strip()
    if line.len == 0: continue

    let parts = line.splitWhitespace()
    if parts.len >= 3 and parts[1].toUpperAscii() == "EQU":
      continue

    if parts[0].toUpperAscii() == "ORG" and parts.len >= 2:
      let target = parts[1].strip()
      if target.startsWith("P:") or target.startsWith("p:"):
        curSpace = MemSpace.memP
        pcP = parseNumberLit(target[2..^1], symbols)
      elif target.startsWith("X:") or target.startsWith("x:"):
        curSpace = MemSpace.memX
        pcX = parseNumberLit(target[2..^1], symbols)
      elif target.startsWith("Y:") or target.startsWith("y:"):
        curSpace = MemSpace.memY
        pcY = parseNumberLit(target[2..^1], symbols)
      continue

    var codeLine = line
    if not (parts[0].toUpperAscii() in [
      "NOP", "RTS", "RTI", "RESET", "WAIT", "STOP", "ENDDO", "JMP", "JSR", "JCC",
      "JEQ", "JNE", "JCS", "JHS", "JLO", "JMI", "JPL", "JGE", "JLT", "JGT", "JLE", "JLC", "JLS", "JEC", "JES", "JNN", "JNR",
      "CLR", "ADD", "SUB", "CMP", "AND", "OR", "EOR", "NOT", "MPY", "MAC", "MACR",
      "ASL", "ASR", "LSR", "NEG", "ABS", "TFR", "TST", "RND", "DO", "REP", "MOVE", "DC", "DS"
    ]):
      if parts[0].endsWith(":") or parts.len == 1:
        codeLine = line[parts[0].len..^1].strip()
      else:
        codeLine = line[parts[0].len..^1].strip()

    if codeLine.len == 0:
      continue

    # Emit helper
    template emitWord(w: uint32) =
      let entry = AsmEntry(address: getPc(), word: w and 0x00FFFFFF'u32)
      case curSpace
      of MemSpace.memP:
        result.pRam.add(entry)
        result.binaryWords.add(w and 0x00FFFFFF'u32)
      of MemSpace.memX:
        result.xRam.add(entry)
      of MemSpace.memY:
        result.yRam.add(entry)
      else:
        result.pRam.add(entry)
      advancePc(1)

    let cparts = codeLine.splitWhitespace()
    let mnem = cparts[0].toUpperAscii()
    let operandStr = codeLine[cparts[0].len..^1].strip()

    case mnem
    of "NOP": emitWord(asmNop())
    of "RTS": emitWord(asmRts())
    of "RTI": emitWord(asmRti())
    of "RESET": emitWord(asmReset())
    of "WAIT": emitWord(asmWait())
    of "STOP": emitWord(asmStop())
    of "ENDDO": emitWord(asmEndDo())
    of "JMP":
      let target = parseNumberLit(operandStr, symbols)
      if target >= 0x1000'u32:
        emitWord(0x0AF080'u32)
        emitWord(target)
      else:
        emitWord(asmJmp(target))
    of "JSR":
      let target = parseNumberLit(operandStr, symbols)
      if target >= 0x1000'u32:
        emitWord(0x0BF080'u32)
        emitWord(target)
      else:
        emitWord(asmJsr(target))
    of "JCC":
      let ops = operandStr.split(',')
      let (_, cond) = parseConditionCode(ops[0])
      let target = parseNumberLit(ops[1], symbols)
      if target >= 0x1000'u32:
        emitWord(0x0AF0A0'u32 or (uint32(ord(cond)) and 0x0F'u32))
        emitWord(target)
      else:
        emitWord(asmJcc(cond, target))
    of "JEQ", "JNE", "JCS", "JHS", "JLO", "JMI", "JPL", "JGE", "JLT", "JGT", "JLE", "JLC", "JLS", "JEC", "JES", "JNN", "JNR":
      let (_, cond) = parseConditionCode(mnem)
      let target = parseNumberLit(operandStr, symbols)
      if target >= 0x1000'u32:
        emitWord(0x0AF0A0'u32 or (uint32(ord(cond)) and 0x0F'u32))
        emitWord(target)
      else:
        emitWord(asmJcc(cond, target))
    of "CLR":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmClr(dst))
    of "ADD":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmAdd(src, dst))
    of "SUB":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmSub(src, dst))
    of "CMP":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmCmp(src, dst))
    of "AND":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmAnd(src, dst))
    of "OR":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmOr(src, dst))
    of "EOR":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmEor(src, dst))
    of "MPY":
      let ops = operandStr.split(',')
      var s1Str = ops[0].strip()
      var neg = false
      if s1Str.startsWith("-"):
        neg = true
        s1Str = s1Str[1..^1].strip()
      let (_, s1) = parseRegId(s1Str)
      let (_, s2) = parseRegId(ops[1])
      let (_, dst) = parseRegId(ops[2])
      emitWord(asmMpy(s1, s2, dst, neg))
    of "MAC":
      let ops = operandStr.split(',')
      var s1Str = ops[0].strip()
      var neg = false
      if s1Str.startsWith("-"):
        neg = true
        s1Str = s1Str[1..^1].strip()
      let (_, s1) = parseRegId(s1Str)
      let (_, s2) = parseRegId(ops[1])
      let (_, dst) = parseRegId(ops[2])
      emitWord(asmMac(s1, s2, dst, neg))
    of "MACR":
      let ops = operandStr.split(',')
      var s1Str = ops[0].strip()
      var neg = false
      if s1Str.startsWith("-"):
        neg = true
        s1Str = s1Str[1..^1].strip()
      let (_, s1) = parseRegId(s1Str)
      let (_, s2) = parseRegId(ops[1])
      let (_, dst) = parseRegId(ops[2])
      emitWord(asmMacr(s1, s2, dst, neg))
    of "ASL":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmAsl(dst))
    of "ASR":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmAsr(dst))
    of "LSR":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmLsr(dst))
    of "NEG":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmNeg(dst))
    of "ABS":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmAbs(dst))
    of "NOT":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmNot(dst))
    of "TFR":
      let ops = operandStr.split(',')
      let (_, src) = parseRegId(ops[0])
      let (_, dst) = parseRegId(ops[1])
      emitWord(asmTfr(src, dst))
    of "TST":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmTst(dst))
    of "RND":
      let (_, dst) = parseRegId(operandStr)
      emitWord(asmRnd(dst))
    of "DO":
      let ops = operandStr.split(',')
      let count = uint16(parseNumberLit(ops[0], symbols))
      let target = parseNumberLit(ops[1], symbols)
      let doWords = asmDoImm(count, target)
      emitWord(doWords[0])
      emitWord(doWords[1])
    of "REP":
      let count = uint16(parseNumberLit(operandStr, symbols))
      emitWord(asmRepImm(count))
    of "DC", "DC.W":
      let vals = operandStr.split(',')
      for v in vals:
        emitWord(parseNumberLit(v, symbols))
    of "DS":
      let cnt = parseNumberLit(operandStr, symbols)
      for i in 0..<cnt:
        emitWord(0'u32)
    of "MOVE":
      let ops = operandStr.split(',')
      let s = ops[0].strip()
      let d = ops[1].strip()
      let (isSrcReg, srcReg) = parseRegId(s)
      let (isDstReg, dstReg) = parseRegId(d)

      if isSrcReg and isDstReg:
        emitWord(asmMoveReg(srcReg, dstReg))
      elif s.startsWith("#") and isDstReg:
        let imm = parseNumberLit(s, symbols)
        let sRaw = s.strip()
        let isExplicit24 = (sRaw.startsWith("#$") or sRaw.startsWith("#0x") or sRaw.startsWith("#0X")) and sRaw.len > 5
        if not isExplicit24 and imm <= 0xFF'u32 and dstReg in {RegId.regX0, RegId.regX1, RegId.regY0, RegId.regY1, RegId.regA0, RegId.regB0, RegId.regA1, RegId.regB1, RegId.regA, RegId.regB}:
          emitWord(asmMoveImmShort(dstReg, uint8(imm)))
        else:
          let w = asmMoveImm24(dstReg, imm)
          emitWord(w[0])
          emitWord(w[1])
      elif isDstReg:
        let memOp = parseMemOperand(s, symbols)
        if memOp.kind == mopAbsolute:
          let w = asmMoveMemAbs(memOp.space, isWrite=false, dstReg, memOp.address)
          emitWord(w[0])
          emitWord(w[1])
        elif memOp.kind == mopIndirect:
          emitWord(asmMoveMemInd(memOp.space, isWrite=false, dstReg, memOp.rNum, memOp.mode))
        else:
          raise newException(ValueError, "Unsupported source operand in MOVE: " & s)
      elif isSrcReg:
        let memOp = parseMemOperand(d, symbols)
        if memOp.kind == mopAbsolute:
          let w = asmMoveMemAbs(memOp.space, isWrite=true, srcReg, memOp.address)
          emitWord(w[0])
          emitWord(w[1])
        elif memOp.kind == mopIndirect:
          emitWord(asmMoveMemInd(memOp.space, isWrite=true, srcReg, memOp.rNum, memOp.mode))
        else:
          raise newException(ValueError, "Unsupported destination operand in MOVE: " & d)
      else:
        raise newException(ValueError, "Unsupported MOVE syntax: " & codeLine)
    else:
      raise newException(ValueError, "Unrecognized instruction mnemonic: " & mnem)

proc assembleFile*(path: string, baseOrg: uint32 = 0): AsmResult =
  let content = readFile(path)
  return assembleText(content, baseOrg)
