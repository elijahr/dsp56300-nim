## Test suite for DSP56300 x86_64 Native JIT Backend
## Tests assembleX86_64 machine-code emission and live execution under Rosetta 2 / amd64.
## Strict TDD: Red -> Green -> Fault-Plant

import std/unittest
import dsp56300/[ir, jit_native]

when defined(amd64):
  import dsp56300/runner

suite "DSP56300 x86_64 Native JIT Compiler Backend":
  test "x86_64 JIT emits valid AMD64 machine code for NOP block":
    var state = newDspState()
    state.pc = 0x100'u32
    state.pRam[0x100] = 0x000000'u32 # NOP

    let blk = liftBasicBlock(state, 0x100'u32, maxWords = 1)
    let code = assembleX86_64(blk)

    check code.len >= 16
    # System V AMD64 Prologue: push rbp; mov rbp, rsp
    check code[0] == 0x55'u8
    check code[1] == 0x48'u8
    check code[2] == 0x89'u8
    check code[3] == 0xE5'u8
    # Retq at end
    check code[^1] == 0xC3'u8

  test "x86_64 JIT emits valid AMD64 machine code for Parallel Move MPY block":
    var state = newDspState()
    state.pc = 0x200'u32
    state.pRam[0x200] = 0xB018D0'u32 # MPY X0, Y0, A  X:(R0)+, X0  Y:(R4)+, Y0

    let blk = liftBasicBlock(state, 0x200'u32, maxWords = 1)
    let code = assembleX86_64(blk)

    # Search for imul rax, rdx: 0x48, 0x0F, 0xAF, 0xC2
    var foundImul = false
    for i in 0 ..< (code.len - 3):
      if code[i] == 0x48'u8 and code[i + 1] == 0x0F'u8 and code[i + 2] == 0xAF'u8 and
          code[i + 3] == 0xC2'u8:
        foundImul = true
        break
    check foundImul

  test "x86_64 JIT emits valid AMD64 machine code for DO Loop block":
    var state = newDspState()
    state.pc = 0x500'u32
    state.pRam[0x500] = 0x060580'u32 # DO #5, $502
    state.pRam[0x501] = 0x000502'u32
    state.pRam[0x502] = 0x000040'u32 # ADD X0, A

    let blk = liftBasicBlock(state, 0x500'u32, maxWords = 3)
    let code = assembleX86_64(blk)

    # Search for decl r12d: 0x41, 0xFF, 0xCC
    var foundDec = false
    for i in 0 ..< (code.len - 2):
      if code[i] == 0x41'u8 and code[i + 1] == 0xFF'u8 and code[i + 2] == 0xCC'u8:
        foundDec = true
        break
    check foundDec

  when defined(amd64):
    test "Live x86_64 execution matches Cold Runner on Biquad filter":
      var runnerState = newDspState()
      var jitState = newDspState()

      proc initBiquad(s: var DspState) =
        s.pc = 0x300'u32
        s.x0 = 0x200000'u32
        s.y0 = 0x400000'u32
        s.r[0] = 0x10'u32
        s.r[4] = 0x20'u32
        s.m[0] = 0xFFFFFF'u32
        s.m[4] = 0xFFFFFF'u32
        s.xRam[0x10] = 0x100000'u32
        s.yRam[0x20] = 0x300000'u32
        s.pRam[0x300] = 0xB018D0'u32

      initBiquad(runnerState)
      initBiquad(jitState)

      let blk = liftBasicBlock(runnerState, 0x300'u32, maxWords = 1)
      let rCycles = runBlock(runnerState, blk)

      let ctx = newNativeJit()
      let fn = ctx.compileBlock(blk)
      check fn != nil
      let jCycles = fn(addr jitState)

      check rCycles == jCycles
      check runnerState.pc == jitState.pc
      check runnerState.getAccA() == jitState.getAccA()
      check runnerState.x0 == jitState.x0
      check runnerState.y0 == jitState.y0
      check runnerState.r[0] == jitState.r[0]
      check runnerState.r[4] == jitState.r[4]
