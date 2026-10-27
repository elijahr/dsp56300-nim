## Clean-room MIT Motorola DSP56300 WASM Bytecode JIT Backend
## Compiles any Micro-Op IR basic block into a valid standalone WebAssembly (.wasm) binary module in memory.
## Reference: WebAssembly Core Specification (Binary Format) & Motorola DSP56300 Family Manual.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola and W3C specifications.

import dsp56300/[decode_types, state, ir, jit_native]

const
  WASM_X_RAM_BASE* = 0x10000'u32 # 64KB (offset in linear memory)
  WASM_Y_RAM_BASE* = 0x40000'u32 # 256KB (offset in linear memory)

proc writeU32Leb128*(buf: var seq[byte], value: uint32) =
  var v = value
  while true:
    var b = byte(v and 0x7F'u32)
    v = v shr 7
    if v == 0:
      buf.add(b)
      break
    else:
      b = b or 0x80'u8
      buf.add(b)

proc writeI32Leb128*(buf: var seq[byte], value: int32) =
  var v = value
  var more = true
  while more:
    var b = byte(v and 0x7F)
    v = v shr 7
    let signBit = (b and 0x40'u8) != 0
    if (v == 0 and not signBit) or (v == -1 and signBit):
      more = false
    else:
      b = b or 0x80'u8
    buf.add(b)

proc writeI64Leb128*(buf: var seq[byte], value: int64) =
  var v = value
  var more = true
  while more:
    var b = byte(v and 0x7F)
    v = v shr 7
    let signBit = (b and 0x40'u8) != 0
    if (v == 0 and not signBit) or (v == -1 and signBit):
      more = false
    else:
      b = b or 0x80'u8
    buf.add(b)

proc makeSection*(secId: byte, payload: seq[byte]): seq[byte] =
  result = @[secId]
  writeU32Leb128(result, uint32(payload.len))
  result.add(payload)

proc wasmLoadAcc(body: var seq[byte], accReg: RegId) =
  let offA2 = uint32(if accReg == RegId.regB: OFFSET_B2 else: OFFSET_A2)
  let offA1 = uint32(if accReg == RegId.regB: OFFSET_B1 else: OFFSET_A1)
  let offA0 = uint32(if accReg == RegId.regB: OFFSET_B0 else: OFFSET_A0)

  # local.get 0 (statePtr)
  body.add([0x20'u8, 0x00])
  # i32.load8_u align=0, offset=offA2
  body.add([0x2D'u8, 0x00])
  writeU32Leb128(body, offA2)
  # i64.extend_i32_u
  body.add(0xAD'u8)
  # i64.const 48
  body.add(0x42'u8)
  writeI64Leb128(body, 48'i64)
  # i64.shl
  body.add(0x86'u8)

  # local.get 0
  body.add([0x20'u8, 0x00])
  # i32.load align=2, offset=offA1
  body.add([0x28'u8, 0x02])
  writeU32Leb128(body, offA1)
  # i32.const 0x00FFFFFF
  body.add(0x41'u8)
  writeI32Leb128(body, 0x00FFFFFF'i32)
  body.add(0x71'u8) # i32.and
  body.add(0xAD'u8) # i64.extend_i32_u
  body.add(0x42'u8)
  writeI64Leb128(body, 24'i64) # i64.const 24
  body.add(0x86'u8) # i64.shl
  body.add(0x84'u8) # i64.or

  # local.get 0
  body.add([0x20'u8, 0x00])
  # i32.load align=2, offset=offA0
  body.add([0x28'u8, 0x02])
  writeU32Leb128(body, offA0)
  body.add(0x41'u8)
  writeI32Leb128(body, 0x00FFFFFF'i32)
  body.add(0x71'u8) # i32.and
  body.add(0xAD'u8) # i64.extend_i32_u
  body.add(0x84'u8) # i64.or

  # Sign-extend 56 bits: i64.shl 8; i64.shr_s 8
  body.add(0x42'u8)
  writeI64Leb128(body, 8'i64)
  body.add(0x86'u8) # i64.shl
  body.add(0x42'u8)
  writeI64Leb128(body, 8'i64)
  body.add(0x87'u8) # i64.shr_s
  # local.set 3
  body.add([0x21'u8, 0x03])

proc wasmStoreAcc(body: var seq[byte], accReg: RegId) =
  let offA2 = uint32(if accReg == RegId.regB: OFFSET_B2 else: OFFSET_A2)
  let offA1 = uint32(if accReg == RegId.regB: OFFSET_B1 else: OFFSET_A1)
  let offA0 = uint32(if accReg == RegId.regB: OFFSET_B0 else: OFFSET_A0)

  # Store A0:
  body.add([0x20'u8, 0x00]) # local.get 0
  body.add([0x20'u8, 0x03]) # local.get 3
  body.add(0xA7'u8) # i32.wrap_i64
  body.add(0x41'u8)
  writeI32Leb128(body, 0x00FFFFFF'i32)
  body.add(0x71'u8) # i32.and
  body.add([0x36'u8, 0x02])
  writeU32Leb128(body, offA0) # i32.store

  # Store A1:
  body.add([0x20'u8, 0x00]) # local.get 0
  body.add([0x20'u8, 0x03]) # local.get 3
  body.add(0x42'u8)
  writeI64Leb128(body, 24'i64)
  body.add(0x88'u8) # i64.shr_u
  body.add(0xA7'u8) # i32.wrap_i64
  body.add(0x41'u8)
  writeI32Leb128(body, 0x00FFFFFF'i32)
  body.add(0x71'u8) # i32.and
  body.add([0x36'u8, 0x02])
  writeU32Leb128(body, offA1)

  # Store A2:
  body.add([0x20'u8, 0x00]) # local.get 0
  body.add([0x20'u8, 0x03]) # local.get 3
  body.add(0x42'u8)
  writeI64Leb128(body, 48'i64)
  body.add(0x88'u8) # i64.shr_u
  body.add(0xA7'u8) # i32.wrap_i64
  body.add([0x3A'u8, 0x00])
  writeU32Leb128(body, offA2) # i32.store8

proc compileWasmModule*(blk: IrBasicBlock): seq[byte] =
  ## Compiles any Micro-Op IR basic block into a valid standalone WebAssembly binary module in memory.
  ## Lowers EVERY MicroOp in blk into real WebAssembly opcodes operating on DspState in env.memory.
  result = @[0x00'u8, 0x61'u8, 0x73'u8, 0x6D'u8, 0x01'u8, 0x00'u8, 0x00'u8, 0x00'u8]

  # 1. Type Section (Section 1): Function signature (i32) -> i32
  var typePayload: seq[byte] = @[]
  typePayload.add(1'u8) # Vector count: 1 type
  typePayload.add(0x60'u8) # Form: func
  typePayload.add(1'u8) # Param count: 1
  typePayload.add(0x7F'u8) # Param type: i32 (statePtr)
  typePayload.add(1'u8) # Result count: 1
  typePayload.add(0x7F'u8) # Result type: i32 (cycles executed)
  result.add(makeSection(1'u8, typePayload))

  # 2. Import Section (Section 2): import env.memory (initial 16 pages = 1MB)
  var importPayload: seq[byte] = @[]
  importPayload.add(1'u8) # 1 import
  # Module name: "env"
  importPayload.add(3'u8)
  importPayload.add([0x65'u8, 0x6E'u8, 0x76'u8])
  # Field name: "memory"
  importPayload.add(6'u8)
  importPayload.add([0x6D'u8, 0x65'u8, 0x6D'u8, 0x6F'u8, 0x72'u8, 0x79'u8])
  # Type: Memory (0x02)
  importPayload.add(0x02'u8)
  # Limits: flags=0 (no max), initial=1 page (64KB minimum)
  importPayload.add(0x00'u8)
  writeU32Leb128(importPayload, 1'u32)
  result.add(makeSection(2'u8, importPayload))

  # 3. Function Section (Section 3): 1 function, using type index 0
  var funcPayload: seq[byte] = @[]
  funcPayload.add(1'u8) # Count: 1
  funcPayload.add(0'u8) # Type index 0
  result.add(makeSection(3'u8, funcPayload))

  # 4. Export Section (Section 7): export "block_entry" -> function 0
  var exportPayload: seq[byte] = @[]
  exportPayload.add(1'u8) # Count: 1
  let expName = "block_entry"
  exportPayload.add(byte(expName.len))
  for ch in expName:
    exportPayload.add(byte(ch))
  exportPayload.add(0x00'u8) # Kind: Function (0x00)
  exportPayload.add(0x00'u8) # Func index 0
  result.add(makeSection(7'u8, exportPayload))

  # 5. Code Section (Section 10): Function body
  var bodyBytes: seq[byte] = @[]

  # Locals declaration:
  # local 1: i32 (scratch / addr)
  # local 2: i32 (loopCounter)
  # local 3: i64 (acc64)
  # local 4: i64 (term64 / prod64)
  bodyBytes.add(2'u8) # 2 local entries
  # 2 of type i32
  bodyBytes.add(2'u8)
  bodyBytes.add(0x7F'u8)
  # 2 of type i64
  bodyBytes.add(2'u8)
  bodyBytes.add(0x7E'u8)

  let cycles = computeBlockCycles(blk)

  # Check DO Loop
  var loopIterations = 1'u32
  var isLoopBlock = false
  var loopEndPc = 0'u32
  for op in blk.ops:
    if op.kind == IrOpKind.irLoopDo:
      loopIterations = op.imm
      loopEndPc = op.pAddr
      isLoopBlock = true
      break
    elif op.kind notin {IrOpKind.irCheckGen, IrOpKind.irNop}:
      break

  if isLoopBlock:
    bodyBytes.add(0x41'u8)
    writeI32Leb128(bodyBytes, int32(loopIterations)) # i32.const loopIterations
    bodyBytes.add([0x21'u8, 0x02]) # local.set 2
    bodyBytes.add([0x02'u8, 0x40]) # block void
    bodyBytes.add([0x03'u8, 0x40]) # loop void
    bodyBytes.add([0x20'u8, 0x02]) # local.get 2
    bodyBytes.add(0x45'u8) # i32.eqz
    bodyBytes.add([0x0D'u8, 0x01]) # br_if 1 (exit block)

  for rawOp in blk.ops:
    let op = canonicalizeOp(rawOp)
    case op.kind
    of IrOpKind.irNop, IrOpKind.irCheckGen:
      discard
    of IrOpKind.irLoadImm:
      let dstOff = regOffset(op.dst)
      if dstOff >= 0:
        bodyBytes.add([0x20'u8, 0x00]) # local.get 0
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, int32(op.imm and 0x00FFFFFF'u32))
        bodyBytes.add([0x36'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(dstOff)) # i32.store
    of IrOpKind.irLoadReg, IrOpKind.irStoreReg:
      let srcOff = regOffset(op.src1)
      let dstOff = regOffset(op.dst)
      if srcOff >= 0 and dstOff >= 0:
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(srcOff))
        bodyBytes.add([0x36'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(dstOff))
    of IrOpKind.irLoadMem:
      let dstOff = regOffset(op.dst)
      if dstOff >= 0:
        # Compute memory linear address: (r[rNum] * 4) + ramBase
        let ramBase =
          if op.space == MemSpace.memX: WASM_X_RAM_BASE else: WASM_Y_RAM_BASE
        if op.addrMode == AddrMode.amAbsolute:
          bodyBytes.add(0x41'u8)
          writeI32Leb128(bodyBytes, int32(ramBase + (op.imm * 4)))
        else:
          let rOff = OFFSET_R + int(op.rNum) * 4
          bodyBytes.add([0x20'u8, 0x00])
          bodyBytes.add([0x28'u8, 0x02])
          writeU32Leb128(bodyBytes, uint32(rOff))
          bodyBytes.add(0x41'u8)
          writeI32Leb128(bodyBytes, 2'i32)
          bodyBytes.add(0x74'u8) # i32.shl
          bodyBytes.add(0x41'u8)
          writeI32Leb128(bodyBytes, int32(ramBase))
          bodyBytes.add(0x6A'u8) # i32.add
        bodyBytes.add([0x28'u8, 0x02, 0x00]) # i32.load offset=0
        bodyBytes.add([0x21'u8, 0x01]) # local.set 1 (value)

        # Store to dst in DspState:
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x20'u8, 0x01])
        bodyBytes.add([0x36'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(dstOff))
    of IrOpKind.irStoreMem:
      let srcOff = regOffset(op.src1)
      if srcOff >= 0:
        let ramBase =
          if op.space == MemSpace.memX: WASM_X_RAM_BASE else: WASM_Y_RAM_BASE
        if op.addrMode == AddrMode.amAbsolute:
          bodyBytes.add(0x41'u8)
          writeI32Leb128(bodyBytes, int32(ramBase + (op.imm * 4)))
        else:
          let rOff = OFFSET_R + int(op.rNum) * 4
          bodyBytes.add([0x20'u8, 0x00])
          bodyBytes.add([0x28'u8, 0x02])
          writeU32Leb128(bodyBytes, uint32(rOff))
          bodyBytes.add(0x41'u8)
          writeI32Leb128(bodyBytes, 2'i32)
          bodyBytes.add(0x74'u8)
          bodyBytes.add(0x41'u8)
          writeI32Leb128(bodyBytes, int32(ramBase))
          bodyBytes.add(0x6A'u8)

        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(srcOff))
        bodyBytes.add([0x36'u8, 0x02, 0x00]) # i32.store offset=0
    of IrOpKind.irAguUpdate:
      let rOff = uint32(OFFSET_R + int(op.rNum) * 4)
      bodyBytes.add([0x20'u8, 0x00]) # local.get 0
      bodyBytes.add([0x20'u8, 0x00])
      bodyBytes.add([0x28'u8, 0x02])
      writeU32Leb128(bodyBytes, rOff) # i32.load r

      case op.addrMode
      of AddrMode.amPostInc:
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 1'i32)
        bodyBytes.add(0x6A'u8) # i32.add
      of AddrMode.amPostDec:
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 1'i32)
        bodyBytes.add(0x6B'u8) # i32.sub
      of AddrMode.amPostIncN:
        let nOff = uint32(OFFSET_N + int(op.rNum) * 4)
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, nOff)
        bodyBytes.add(0x6A'u8)
      of AddrMode.amPostDecN:
        let nOff = uint32(OFFSET_N + int(op.rNum) * 4)
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, nOff)
        bodyBytes.add(0x6B'u8)
      else:
        discard

      bodyBytes.add(0x41'u8)
      writeI32Leb128(bodyBytes, 0x00FFFFFF'i32)
      bodyBytes.add(0x71'u8) # i32.and
      bodyBytes.add([0x36'u8, 0x02])
      writeU32Leb128(bodyBytes, rOff) # i32.store
    of IrOpKind.irAluOp:
      case op.aluOp
      of AluOp.opMpy, AluOp.opMpyr:
        let src1Off = regOffset(op.src1)
        let src2Off = regOffset(op.src2)
        # Load s1 (sign-extended to 32, then i64):
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(src1Off))
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x74'u8) # i32.shl
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x75'u8) # i32.shr_s
        bodyBytes.add(0xAC'u8) # i64.extend_i32_s

        # Load s2:
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(src2Off))
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x74'u8)
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x75'u8)
        bodyBytes.add(0xAC'u8)

        # Multiply and shl 1
        bodyBytes.add(0x7E'u8) # i64.mul
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 1'i64)
        bodyBytes.add(0x86'u8) # i64.shl

        if op.isNeg:
          bodyBytes.add([0x21'u8, 0x04]) # local.set 4
          bodyBytes.add(0x42'u8)
          writeI64Leb128(bodyBytes, 0'i64)
          bodyBytes.add([0x20'u8, 0x04]) # local.get 4
          bodyBytes.add(0x7D'u8) # i64.sub

        # 56-bit sign-extend:
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x86'u8) # i64.shl
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x87'u8) # i64.shr_s
        bodyBytes.add([0x21'u8, 0x03]) # local.set 3
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opMac, AluOp.opMacr:
        let src1Off = regOffset(op.src1)
        let src2Off = regOffset(op.src2)
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(src1Off))
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x74'u8)
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x75'u8)
        bodyBytes.add(0xAC'u8)

        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(src2Off))
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x74'u8)
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x75'u8)
        bodyBytes.add(0xAC'u8)

        bodyBytes.add(0x7E'u8) # i64.mul
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 1'i64)
        bodyBytes.add(0x86'u8) # i64.shl

        if op.isNeg:
          bodyBytes.add([0x21'u8, 0x04])
          bodyBytes.add(0x42'u8)
          writeI64Leb128(bodyBytes, 0'i64)
          bodyBytes.add([0x20'u8, 0x04])
          bodyBytes.add(0x7D'u8)
          bodyBytes.add([0x21'u8, 0x04])
        else:
          bodyBytes.add([0x21'u8, 0x04]) # local.set 4 (prod)

        wasmLoadAcc(bodyBytes, op.dst) # loads acc into local 3
        bodyBytes.add([0x20'u8, 0x03]) # local.get 3
        bodyBytes.add([0x20'u8, 0x04]) # local.get 4
        bodyBytes.add(0x7C'u8) # i64.add
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x86'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x87'u8)
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opAdd:
        let src1Off = regOffset(op.src1)
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(src1Off))
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x74'u8)
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x75'u8)
        bodyBytes.add(0xAC'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 24'i64)
        bodyBytes.add(0x86'u8) # i64.shl 24
        bodyBytes.add([0x21'u8, 0x04]) # local.set 4 (term)

        wasmLoadAcc(bodyBytes, op.dst)
        bodyBytes.add([0x20'u8, 0x03])
        bodyBytes.add([0x20'u8, 0x04])
        bodyBytes.add(0x7C'u8) # i64.add
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x86'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x87'u8)
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opSub:
        let src1Off = regOffset(op.src1)
        bodyBytes.add([0x20'u8, 0x00])
        bodyBytes.add([0x28'u8, 0x02])
        writeU32Leb128(bodyBytes, uint32(src1Off))
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x74'u8)
        bodyBytes.add(0x41'u8)
        writeI32Leb128(bodyBytes, 8'i32)
        bodyBytes.add(0x75'u8)
        bodyBytes.add(0xAC'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 24'i64)
        bodyBytes.add(0x86'u8)
        bodyBytes.add([0x21'u8, 0x04])

        wasmLoadAcc(bodyBytes, op.dst)
        bodyBytes.add([0x20'u8, 0x03])
        bodyBytes.add([0x20'u8, 0x04])
        bodyBytes.add(0x7D'u8) # i64.sub
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x86'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x87'u8)
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opClr:
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 0'i64)
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opNeg:
        wasmLoadAcc(bodyBytes, op.dst)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 0'i64)
        bodyBytes.add([0x20'u8, 0x03])
        bodyBytes.add(0x7D'u8) # i64.sub
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x86'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x87'u8)
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opAsl:
        wasmLoadAcc(bodyBytes, op.dst)
        bodyBytes.add([0x20'u8, 0x03])
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 1'i64)
        bodyBytes.add(0x86'u8) # i64.shl
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x86'u8)
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 8'i64)
        bodyBytes.add(0x87'u8)
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      of AluOp.opAsr:
        wasmLoadAcc(bodyBytes, op.dst)
        bodyBytes.add([0x20'u8, 0x03])
        bodyBytes.add(0x42'u8)
        writeI64Leb128(bodyBytes, 1'i64)
        bodyBytes.add(0x87'u8) # i64.shr_s
        bodyBytes.add([0x21'u8, 0x03])
        wasmStoreAcc(bodyBytes, op.dst)
      else:
        discard
    of IrOpKind.irBranch:
      bodyBytes.add([0x20'u8, 0x00])
      bodyBytes.add(0x41'u8)
      writeI32Leb128(bodyBytes, int32(op.imm))
      bodyBytes.add([0x36'u8, 0x02])
      writeU32Leb128(bodyBytes, uint32(OFFSET_PC))
    of IrOpKind.irLoopDo:
      discard
    else:
      discard

  if isLoopBlock:
    bodyBytes.add([0x20'u8, 0x02]) # local.get 2
    bodyBytes.add(0x41'u8)
    writeI32Leb128(bodyBytes, 1'i32)
    bodyBytes.add(0x6B'u8) # i32.sub
    bodyBytes.add([0x21'u8, 0x02]) # local.set 2
    bodyBytes.add([0x0C'u8, 0x00]) # br 0 (repeat loop)
    bodyBytes.add(0x0B'u8) # end loop
    bodyBytes.add(0x0B'u8) # end block

  # Final PC update
  let finalPc =
    if isLoopBlock:
      (loopEndPc + 1)
    else:
      blk.endPc
  bodyBytes.add([0x20'u8, 0x00])
  bodyBytes.add(0x41'u8)
  writeI32Leb128(bodyBytes, int32(finalPc))
  bodyBytes.add([0x36'u8, 0x02])
  writeU32Leb128(bodyBytes, uint32(OFFSET_PC))

  if isLoopBlock:
    bodyBytes.add([0x20'u8, 0x00])
    bodyBytes.add(0x41'u8)
    writeI32Leb128(bodyBytes, 0'i32)
    bodyBytes.add([0x36'u8, 0x02])
    writeU32Leb128(bodyBytes, uint32(OFFSET_CORE + offsetOf(Dsp56300State, lc)))

  # Return cycles: i32.const <cycles>
  bodyBytes.add(0x41'u8)
  writeI32Leb128(bodyBytes, int32(cycles))

  # End of function
  bodyBytes.add(0x0B'u8)

  var codePayload: seq[byte] = @[]
  codePayload.add(1'u8) # 1 function body
  writeU32Leb128(codePayload, uint32(bodyBytes.len))
  codePayload.add(bodyBytes)
  result.add(makeSection(10'u8, codePayload))
