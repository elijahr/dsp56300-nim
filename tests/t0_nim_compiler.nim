## `t0_nim_compiler` - Verification of High-Level Idiomatic Nim AST Compiler for DSP56300
##
## Tests compilation of idiomatic Nim code (variables, while, if/elif/else, xMem, yMem, math)
## into 24-bit DSP56300 machine instructions and runs them on the emulator.

import unittest
import dsp56300/[state, memory, decode_types, runner]
import dsp56300/nim_compiler

suite "DSP56300 Idiomatic Nim Compiler Macro":
  test "Compile basic arithmetic and memory load/store":
    const prog = compileDsp56300:
      xMem[0x10] = 42
      yMem[0x20] = xMem[0x10] + 100
      xMem[0x30] = yMem[0x20] - 20

    check prog.len > 0

    var s = newDspState()
    s.pc = 0'u32
    for i, w in prog:
      s.pRam[uint32(i)] = w

    let blk = liftBasicBlock(s, 0'u32, maxWords = uint32(prog.len))
    let cycles = runBlock(s, blk)
    check cycles > 0

    let v1 = s.xRam[0x10'u32]
    let v2 = s.yRam[0x20'u32]
    let v3 = s.xRam[0x30'u32]

    check v1 == 42'u32
    check v2 == 142'u32
    check v3 == 122'u32

  test "Compile conditional branching (if/elif/else)":
    const prog = compileDsp56300:
      let mode = xMem[0x10]
      if mode == 1:
        yMem[0x20] = 111
      elif mode == 2:
        yMem[0x20] = 222
      else:
        yMem[0x20] = 333

    check prog.len > 0

    proc runProg(s: var DspState) =
      s.pc = 0'u32
      for i, w in prog:
        s.pRam[uint32(i)] = w
      for _ in 0 ..< 20:
        let blk = liftBasicBlock(s, s.pc, maxWords = 16)
        if blk.ops.len == 0: break
        discard runBlock(s, blk)
        if s.pc >= uint32(prog.len): break

    # Case 1: mode = 2 -> expected yMem[0x20] == 222
    var s1 = newDspState()
    s1.xRam[0x10'u32] = 2'u32
    runProg(s1)
    check s1.yRam[0x20'u32] == 222'u32

    # Case 2: mode = 99 -> expected yMem[0x20] == 333
    var s2 = newDspState()
    s2.xRam[0x10'u32] = 99'u32
    runProg(s2)
    check s2.yRam[0x20'u32] == 333'u32

  test "Compile phase accumulator and math operators":
    const prog = compileDsp56300:
      # Phase accumulator
      let phase = yMem[0x10]
      let inc = xMem[0x11]
      yMem[0x10] = phase + inc

      # Multiplier
      let c = xMem[0x12]
      let f = mpy(c, c)
      xMem[0x13] = asr(f)

    var s = newDspState()
    s.pc = 0'u32
    for i, w in prog:
      s.pRam[uint32(i)] = w

    s.yRam[0x10'u32] = 0x1000'u32
    s.xRam[0x11'u32] = 0x0500'u32
    s.xRam[0x12'u32] = 0x400000'u32 # 0.5 in 24-bit fixed point

    for _ in 0 ..< 20:
      let blk = liftBasicBlock(s, s.pc, maxWords = 16)
      if blk.ops.len == 0: break
      discard runBlock(s, blk)
      if s.pc >= uint32(prog.len): break

    check s.yRam[0x10'u32] == 0x1500'u32
    # 0.5 * 0.5 = 0.25 (0x200000) >> 1 = 0.125 (0x100000)
    check s.xRam[0x13'u32] == 0x100000'u32
