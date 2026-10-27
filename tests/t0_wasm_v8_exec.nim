## Full End-to-End V8 Execution Test Suite for DSP56300 WASM JIT
## Executes compiled WebAssembly bytecode inside real Node.js V8 WebAssembly engine.
## Tests full mutation of DspState, X-RAM, Y-RAM, and Accumulators in linear memory.
## Reference: W3C WebAssembly Specification & DSP56300FM.
## Strict TDD: Red -> Green -> Fault-Plant

import std/[json, os, osproc, strformat, strutils, unittest]
import dsp56300/[state, ir, runner, jit_native, jit_wasm]

suite "DSP56300 WASM JIT V8 Live Execution Suite":
  test "Kernel 1: Biquad IIR Filter execution in V8 WebAssembly matches Cold Runner":
    var runnerState = newDspState()
    runnerState.pc = 0x300'u32
    runnerState.x0 = 0x200000'u32 # 0.25
    runnerState.y0 = 0x400000'u32 # 0.5
    runnerState.r[0] = 0x10'u32
    runnerState.r[4] = 0x20'u32
    runnerState.m[0] = 0xFFFFFF'u32
    runnerState.m[4] = 0xFFFFFF'u32
    runnerState.xRam[0x10] = 0x100000'u32 # b1
    runnerState.yRam[0x20] = 0x300000'u32 # x[n-1]
    # MPY X0, Y0, A  X:(R0)+, X1  Y:(R4)+, Y1
    runnerState.pRam[0x300] = 0xB018D0'u32

    let blk = liftBasicBlock(runnerState, 0x300'u32, maxWords = 1)
    let rCycles = runBlock(runnerState, blk)
    let wasmBytes = compileWasmModule(blk)

    let wasmPath = getTempDir() / "test_biquad.wasm"
    writeFile(wasmPath, cast[string](wasmBytes))

    let offX0 = OFFSET_X0
    let offY0 = OFFSET_Y0
    let offX1 = OFFSET_X1
    let offY1 = OFFSET_Y1
    let offR0 = OFFSET_R + 0
    let offR4 = OFFSET_R + 16
    let offPC = OFFSET_PC
    let offA0 = OFFSET_A0
    let offA1 = OFFSET_A1
    let offA2 = OFFSET_A2
    let xRamOffset = WASM_X_RAM_BASE + (0x10'u32 * 4)
    let yRamOffset = WASM_Y_RAM_BASE + (0x20'u32 * 4)

    let nodeScript = &"""
    const fs = require('fs');
    const wasmBuf = fs.readFileSync('{wasmPath}');
    const mod = new WebAssembly.Module(wasmBuf);
    const mem = new WebAssembly.Memory({{ initial: 16 }});
    const inst = new WebAssembly.Instance(mod, {{ env: {{ memory: mem }} }});

    const u8 = new Uint8Array(mem.buffer);
    const u32 = new Uint32Array(mem.buffer);

    // Populate DspState
    u32[{offX0} / 4] = 0x200000;
    u32[{offY0} / 4] = 0x400000;
    u32[{offR0} / 4] = 0x10;
    u32[{offR4} / 4] = 0x20;
    u32[{offPC} / 4] = 0x300;

    // Populate X and Y RAM
    u32[{xRamOffset} / 4] = 0x100000;
    u32[{yRamOffset} / 4] = 0x300000;

    const cycles = inst.exports.block_entry(0);

    // Read back mutated state
    const outX0 = u32[{offX0} / 4];
    const outY0 = u32[{offY0} / 4];
    const outX1 = u32[{offX1} / 4];
    const outY1 = u32[{offY1} / 4];
    const outR0 = u32[{offR0} / 4];
    const outR4 = u32[{offR4} / 4];
    const outPC = u32[{offPC} / 4];
    const outA0 = u32[{offA0} / 4];
    const outA1 = u32[{offA1} / 4];
    const outA2 = u8[{offA2}];

    // Assemble 56-bit accumulator
    let rawAcc = (BigInt(outA2) << 48n) | (BigInt(outA1 & 0x00FFFFFF) << 24n) | BigInt(outA0 & 0x00FFFFFF);
    if ((rawAcc & (1n << 55n)) !== 0n) {{
      rawAcc = rawAcc - (1n << 56n);
    }}

    console.log(JSON.stringify({{
      cycles: cycles,
      pc: outPC,
      x0: outX0,
      y0: outY0,
      x1: outX1,
      y1: outY1,
      r0: outR0,
      r4: outR4,
      accA: rawAcc.toString()
    }}));
    """

    let (output, exitCode) = execCmdEx(&"node -e \"{nodeScript}\"")
    removeFile(wasmPath)

    check exitCode == 0
    let data = parseJson(output.strip())
    check data["cycles"].getInt() == int(rCycles)
    check uint32(data["pc"].getInt()) == runnerState.pc
    check uint32(data["x0"].getInt()) == runnerState.x0
    check uint32(data["y0"].getInt()) == runnerState.y0
    check uint32(data["x1"].getInt()) == runnerState.x1
    check uint32(data["y1"].getInt()) == runnerState.y1
    check uint32(data["r0"].getInt()) == runnerState.r[0]
    check uint32(data["r4"].getInt()) == runnerState.r[4]
    check data["accA"].getStr() == $runnerState.getAccA()

  test "Kernel 2: Oscillator / Accumulator execution in V8 matches Cold Runner":
    var runnerState = newDspState()
    runnerState.pc = 0x400'u32
    runnerState.x0 = 0x000100'u32 # frequency delta step
    runnerState.a1 = 0x001000'u32 # phase accumulator
    runnerState.pRam[0x400] = 0x000040'u32 # ADD X0, A

    let blk = liftBasicBlock(runnerState, 0x400'u32, maxWords = 1)
    let rCycles = runBlock(runnerState, blk)
    let wasmBytes = compileWasmModule(blk)

    let wasmPath = getTempDir() / "test_osc.wasm"
    writeFile(wasmPath, cast[string](wasmBytes))

    let offX0 = OFFSET_X0
    let offA1 = OFFSET_A1
    let offA0 = OFFSET_A0
    let offA2 = OFFSET_A2
    let offPC = OFFSET_PC

    let nodeScript = &"""
    const fs = require('fs');
    const wasmBuf = fs.readFileSync('{wasmPath}');
    const mod = new WebAssembly.Module(wasmBuf);
    const mem = new WebAssembly.Memory({{ initial: 16 }});
    const inst = new WebAssembly.Instance(mod, {{ env: {{ memory: mem }} }});

    const u8 = new Uint8Array(mem.buffer);
    const u32 = new Uint32Array(mem.buffer);

    u32[{offX0} / 4] = 0x000100;
    u32[{offA1} / 4] = 0x001000;
    u32[{offPC} / 4] = 0x400;

    const cycles = inst.exports.block_entry(0);

    const outPC = u32[{offPC} / 4];
    const outA0 = u32[{offA0} / 4];
    const outA1 = u32[{offA1} / 4];
    const outA2 = u8[{offA2}];

    let rawAcc = (BigInt(outA2) << 48n) | (BigInt(outA1 & 0x00FFFFFF) << 24n) | BigInt(outA0 & 0x00FFFFFF);
    if ((rawAcc & (1n << 55n)) !== 0n) {{
      rawAcc = rawAcc - (1n << 56n);
    }}

    console.log(JSON.stringify({{
      cycles: cycles,
      pc: outPC,
      accA: rawAcc.toString()
    }}));
    """

    let (output, exitCode) = execCmdEx(&"node -e \"{nodeScript}\"")
    removeFile(wasmPath)

    check exitCode == 0
    let data = parseJson(output.strip())
    check data["cycles"].getInt() == int(rCycles)
    check uint32(data["pc"].getInt()) == runnerState.pc
    check data["accA"].getStr() == $runnerState.getAccA()

  test "Kernel 3: DO Loop Block execution in V8 matches Cold Runner":
    var runnerState = newDspState()
    runnerState.pc = 0x500'u32
    runnerState.a1 = 0'u32
    runnerState.x0 = 0x00000A'u32 # add 10 each loop
    runnerState.pRam[0x500] = 0x060580'u32 # DO #5, $502
    runnerState.pRam[0x501] = 0x000502'u32
    runnerState.pRam[0x502] = 0x000040'u32 # ADD X0, A

    let blk = liftBasicBlock(runnerState, 0x500'u32, maxWords = 3)
    let rCycles = runBlock(runnerState, blk)
    let wasmBytes = compileWasmModule(blk)

    let wasmPath = getTempDir() / "test_loop.wasm"
    writeFile(wasmPath, cast[string](wasmBytes))

    let offX0 = OFFSET_X0
    let offA1 = OFFSET_A1
    let offPC = OFFSET_PC

    let nodeScript = &"""
    const fs = require('fs');
    const wasmBuf = fs.readFileSync('{wasmPath}');
    const mod = new WebAssembly.Module(wasmBuf);
    const mem = new WebAssembly.Memory({{ initial: 16 }});
    const inst = new WebAssembly.Instance(mod, {{ env: {{ memory: mem }} }});

    const u32 = new Uint32Array(mem.buffer);

    u32[{offX0} / 4] = 0x00000A;
    u32[{offA1} / 4] = 0;
    u32[{offPC} / 4] = 0x500;

    const cycles = inst.exports.block_entry(0);

    const outPC = u32[{offPC} / 4];
    const outA1 = u32[{offA1} / 4];

    console.log(JSON.stringify({{
      cycles: cycles,
      pc: outPC,
      a1: outA1
    }}));
    """

    let (output, exitCode) = execCmdEx(&"node -e \"{nodeScript}\"")
    removeFile(wasmPath)

    check exitCode == 0
    let data = parseJson(output.strip())
    check data["cycles"].getInt() == int(rCycles)
    check uint32(data["pc"].getInt()) == runnerState.pc
    check uint32(data["a1"].getInt()) == runnerState.a1
    check runnerState.a1 == 50'u32
