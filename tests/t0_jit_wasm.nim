## Test suite for DSP56300 WASM Bytecode JIT Backend
## Strict TDD: Red -> Green -> Fault-Plant

import std/[os, osproc, strformat, strutils, unittest]
import dsp56300/[ir, jit_wasm]

suite "DSP56300 WASM Bytecode JIT Backend":
  test "WASM JIT emits valid standalone binary module format":
    var state = newDspState()
    state.pc = 0x100'u32
    state.pRam[0x100] = 0x000000'u32 # NOP

    let blk = liftBasicBlock(state, 0x100'u32, maxWords = 1)
    let wasmBytes = compileWasmModule(blk)

    # 1. Check Magic Header: \0asm
    check wasmBytes.len >= 8
    check wasmBytes[0] == 0x00'u8
    check wasmBytes[1] == 0x61'u8 # 'a'
    check wasmBytes[2] == 0x73'u8 # 's'
    check wasmBytes[3] == 0x6D'u8 # 'm'

    # 2. Check WASM Version: 1
    check wasmBytes[4] == 0x01'u8
    check wasmBytes[5] == 0x00'u8
    check wasmBytes[6] == 0x00'u8
    check wasmBytes[7] == 0x00'u8

  test "WASM JIT module validates and executes in Node.js V8 WebAssembly engine":
    var state = newDspState()
    state.pc = 0x200'u32
    state.pRam[0x200] = 0x000000'u32 # NOP

    let blk = liftBasicBlock(state, 0x200'u32, maxWords = 1)
    let wasmBytes = compileWasmModule(blk)

    # Write WASM binary to temp file and validate with Node.js
    let wasmPath = getTempDir() / "test_block.wasm"
    writeFile(wasmPath, cast[string](wasmBytes))

    let nodeScript = &"""
    const fs = require('fs');
    const wasmBuffer = fs.readFileSync('{wasmPath}');
    const isValid = WebAssembly.validate(wasmBuffer);
    if (!isValid) {{
      console.error('WASM validation failed');
      process.exit(1);
    }}
    const mem = new WebAssembly.Memory({{ initial: 1 }});
    const mod = new WebAssembly.Module(wasmBuffer);
    const inst = new WebAssembly.Instance(mod, {{ env: {{ memory: mem }} }});
    const cycles = inst.exports.block_entry(100);
    console.log('CYCLES:' + cycles);
    """

    let (output, exitCode) = execCmdEx(&"node -e \"{nodeScript}\"")
    removeFile(wasmPath)

    check exitCode == 0
    check "CYCLES:1" in output
