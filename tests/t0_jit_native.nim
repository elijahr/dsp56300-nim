## Test suite for DSP56300 Native JIT Backend (ARM64 / x86_64)
## Strict TDD: Red -> Green -> Fault-Plant

import std/unittest
import dsp56300/[ir, runner, jit_native]

suite "DSP56300 Native JIT Compiler Backend":

  test "Native JIT compiles and executes NOP block":
    var state = newDspState()
    state.pc = 0x100'u32
    state.pRam[0x100] = 0x000000'u32 # NOP

    let blk = liftBasicBlock(state, 0x100'u32, maxWords = 1)
    let jitCtx = newNativeJit()
    let fn = jitCtx.compileBlock(blk)
    check fn != nil

    let cycles = fn(addr state)
    check cycles >= 1
    check state.pc == 0x101'u32

  test "Native JIT differential verification with Cold Runner on Parallel Move":
    var runnerState = newDspState()
    var jitState = newDspState()

    proc initTestState(s: var DspState) =
      s.pc = 0x200'u32
      s.x0 = 0x200000'u32 # 0.25
      s.y0 = 0x400000'u32 # 0.5
      s.r[0] = 0x50'u32
      s.r[4] = 0x60'u32
      s.m[0] = 0xFFFFFF'u32
      s.m[4] = 0xFFFFFF'u32
      s.xRam[0x50] = 0x123456'u32
      s.yRam[0x60] = 0x654321'u32
      # MPY X0, Y0, A  X:(R0)+, X0  Y:(R4)+, Y0
      s.pRam[0x200] = 0xB018D0'u32

    initTestState(runnerState)
    initTestState(jitState)

    let blk = liftBasicBlock(runnerState, 0x200'u32, maxWords = 1)

    # Execute with Cold Runner
    let runnerCycles = runBlock(runnerState, blk)

    # Execute with Native JIT
    let jitCtx = newNativeJit()
    let fn = jitCtx.compileBlock(blk)
    check fn != nil
    let jitCycles = fn(addr jitState)

    # Differential equivalence assertions
    check jitCycles == runnerCycles
    check jitState.pc == runnerState.pc
    check jitState.getAccA() == runnerState.getAccA()
    check jitState.x0 == runnerState.x0
    check jitState.y0 == runnerState.y0
    check jitState.r[0] == runnerState.r[0]
    check jitState.r[4] == runnerState.r[4]
