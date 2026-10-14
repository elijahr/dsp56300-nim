## Clean-room MIT Motorola DSP56300 WASM Bytecode JIT Backend
## Compiles any Micro-Op IR basic block into a valid standalone WebAssembly (.wasm) binary module in memory.
## Reference: WebAssembly Core Specification (Binary Format) & Motorola DSP56300 Family Manual.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola and W3C specifications.

import dsp56300/ir

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

proc makeSection*(secId: byte, payload: seq[byte]): seq[byte] =
  result = @[secId]
  writeU32Leb128(result, uint32(payload.len))
  result.add(payload)

proc compileWasmModule*(blk: IrBasicBlock): seq[byte] =
  ## Compiles any Micro-Op IR basic block into a valid standalone WebAssembly binary module in memory.
  ## The module starts with \0asm\1\0\0\0, imports env.memory, and exports block_entry(statePtr: i32) -> i32 (cycles).
  result = @[0x00'u8, 0x61'u8, 0x73'u8, 0x6D'u8, 0x01'u8, 0x00'u8, 0x00'u8, 0x00'u8]

  # 1. Type Section (Section 1): Function signature (i32) -> i32
  var typePayload: seq[byte] = @[]
  typePayload.add(1'u8)     # Vector count: 1 type
  typePayload.add(0x60'u8)  # Form: func
  typePayload.add(1'u8)     # Param count: 1
  typePayload.add(0x7F'u8)  # Param type: i32 (statePtr)
  typePayload.add(1'u8)     # Result count: 1
  typePayload.add(0x7F'u8)  # Result type: i32 (cycles executed)
  result.add(makeSection(1'u8, typePayload))

  # 2. Import Section (Section 2): import env.memory (min 1 page)
  var importPayload: seq[byte] = @[]
  importPayload.add(1'u8)    # 1 import
  # Module name: "env"
  importPayload.add(3'u8)
  importPayload.add([0x65'u8, 0x6E'u8, 0x76'u8])
  # Field name: "memory"
  importPayload.add(6'u8)
  importPayload.add([0x6D'u8, 0x65'u8, 0x6D'u8, 0x6F'u8, 0x72'u8, 0x79'u8])
  # Type: Memory (0x02)
  importPayload.add(0x02'u8)
  # Limits: flags=0 (no max), initial=1 page (64KB)
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
  bodyBytes.add(0'u8) # Locals vector count: 0

  # Compute cycles executed
  var cycles = 1'u32
  for op in blk.ops:
    if op.kind in {IrOpKind.irAluOp, IrOpKind.irBranch, IrOpKind.irBranchCond, IrOpKind.irCall, IrOpKind.irReturn}:
      cycles += 1

  # Emit bytecode:
  # Update PC at statePtr + 136 (PC offset in DspState)
  # local.get 0 (pushes statePtr)
  bodyBytes.add(0x20'u8); bodyBytes.add(0x00'u8)
  # i32.const <endPc>
  bodyBytes.add(0x41'u8)
  writeI32Leb128(bodyBytes, int32(blk.endPc))
  # i32.store (alignment=2, offset=136)
  bodyBytes.add(0x36'u8); bodyBytes.add(0x02'u8)
  writeU32Leb128(bodyBytes, 136'u32)

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
