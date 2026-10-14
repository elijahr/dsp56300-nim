## Comprehensive Differential Verification Suite for DSP Kernels
## Verifies Cold-Block IR Runner == Native JIT (and WASM JIT compilation)
## Reference: DSP56300FM Appendix B Benchmark Programs:
## B.13 Second Order Real Biquad IIR Filter, Oscillator, DO FOREVER loop

import std/unittest
import dsp56300/[ir, runner, jit_native, jit_wasm]

suite "DSP Kernel Differential Verification Suite (Runner vs Native JIT vs WASM)":

  test "Kernel 1: Biquad IIR Filter Differential (Runner == Native JIT)":
    # DSP56300 Biquad filter difference equation:
    # y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
    # In DSP assembly:
    # MPY  X0, Y0, A   X:(R0)+, X1  Y:(R4)+, Y1
    # MAC  X1, Y1, A   X:(R0)+, X0  Y:(R4)+, Y0
    # MACR X0, Y0, A   X:(R0)-, X1  Y:(R4)-, Y1
    var runnerState = newDspState()
    var jitState = newDspState()

    proc setupBiquadState(s: var DspState) =
      s.pc = 0x300'u32
      s.x0 = 0x200000'u32 # b0 = 0.25
      s.y0 = 0x400000'u32 # x[n] = 0.5
      s.r[0] = 0x10'u32   # coefficients buffer in X
      s.r[4] = 0x20'u32   # state/delay line in Y
      s.m[0] = 0xFFFFFF'u32
      s.m[4] = 0xFFFFFF'u32

      # Coefficients in X
      s.xRam[0x10] = 0x100000'u32 # b1
      s.xRam[0x11] = 0x080000'u32 # b2
      # States in Y
      s.yRam[0x20] = 0x300000'u32 # x[n-1]
      s.yRam[0x21] = 0x180000'u32 # x[n-2]

      # Instruction 1: MPY X0, Y0, A  X:(R0)+, X1  Y:(R4)+, Y1 (0xB018D0)
      s.pRam[0x300] = 0xB018D0'u32

    setupBiquadState(runnerState)
    setupBiquadState(jitState)

    let blk = liftBasicBlock(runnerState, 0x300'u32, maxWords = 1)

    # 1. Execute Runner
    let rCycles = runBlock(runnerState, blk)

    # 2. Execute Native JIT
    let jitCtx = newNativeJit()
    let fn = jitCtx.compileBlock(blk)
    check fn != nil
    let jCycles = fn(addr jitState)

    # 3. Compile to WASM module and verify binary integrity
    let wasm = compileWasmModule(blk)
    check wasm.len > 0
    check wasm[0..3] == [0x00'u8, 0x61'u8, 0x73'u8, 0x6D'u8]

    # Differential match assertions
    check rCycles == jCycles
    check runnerState.pc == jitState.pc
    check runnerState.getAccA() == jitState.getAccA()
    check runnerState.x0 == jitState.x0
    check runnerState.y0 == jitState.y0
    check runnerState.r[0] == jitState.r[0]
    check runnerState.r[4] == jitState.r[4]

  test "Kernel 2: Oscillator / Accumulator Kernel Differential (Runner == Native JIT)":
    # Tight accumulator update: ADD X0, A
    var runnerState = newDspState()
    var jitState = newDspState()

    proc setupOscState(s: var DspState) =
      s.pc = 0x400'u32
      s.x0 = 0x000100'u32 # frequency delta step
      s.a1 = 0x001000'u32 # phase accumulator
      s.pRam[0x400] = 0x000040'u32 # ADD X0, A

    setupOscState(runnerState)
    setupOscState(jitState)

    let blk = liftBasicBlock(runnerState, 0x400'u32, maxWords = 1)
    let rCycles = runBlock(runnerState, blk)

    let jitCtx = newNativeJit()
    let fn = jitCtx.compileBlock(blk)
    let jCycles = fn(addr jitState)

    check rCycles == jCycles
    check runnerState.pc == jitState.pc
    check runnerState.getAccA() == jitState.getAccA()

  test "Kernel 3: DO Loop Block Differential (Runner == Native JIT)":
    var runnerState = newDspState()
    var jitState = newDspState()

    proc setupLoopState(s: var DspState) =
      s.pc = 0x500'u32
      s.a1 = 0'u32
      s.x0 = 0x00000A'u32 # add 10 each loop
      # DO #5, $503
      s.pRam[0x500] = 0x060580'u32
      s.pRam[0x501] = 0x000502'u32
      # ADD X0, A
      s.pRam[0x502] = 0x000040'u32

    setupLoopState(runnerState)
    setupLoopState(jitState)

    let blk = liftBasicBlock(runnerState, 0x500'u32, maxWords = 3)
    let rCycles = runBlock(runnerState, blk)

    let jitCtx = newNativeJit()
    let fn = jitCtx.compileBlock(blk)
    let jCycles = fn(addr jitState)

    check rCycles == jCycles
    check runnerState.pc == jitState.pc
    check runnerState.a1 == jitState.a1
    check runnerState.a1 == 50'u32 # 10 * 5 = 50
