## `t0_nim_compiler` - Verification of High-Level Idiomatic Nim AST Compiler for DSP56300
##
## Tests compilation of idiomatic Nim code (variables, while, if/elif/else, xMem, yMem, math)
## into 24-bit DSP56300 machine instructions and runs them on the emulator.

import unittest
import dsp56300/[state, memory, decode_types, runner, ir]
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

    let blk = liftBasicBlock(s, 0'u32, maxWords = prog.len)
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

  test "Compile case statement branching":
    const prog = compileDsp56300:
      let op = xMem[0x10]
      case op
      of 1:
        xMem[0x20] = 1000
      of 2:
        xMem[0x20] = 2000
      else:
        xMem[0x20] = 9999

    proc runProg(s: var DspState) =
      s.pc = 0'u32
      for i, w in prog:
        s.pRam[uint32(i)] = w
      for _ in 0 ..< 20:
        let blk = liftBasicBlock(s, s.pc, maxWords = 16)
        if blk.ops.len == 0: break
        discard runBlock(s, blk)
        if s.pc >= uint32(prog.len): break

    var s1 = newDspState()
    s1.xRam[0x10'u32] = 1'u32
    runProg(s1)
    check s1.xRam[0x20'u32] == 1000'u32

    var s2 = newDspState()
    s2.xRam[0x10'u32] = 2'u32
    runProg(s2)
    check s2.xRam[0x20'u32] == 2000'u32

    var s3 = newDspState()
    s3.xRam[0x10'u32] = 7'u32
    runProg(s3)
    check s3.xRam[0x20'u32] == 9999'u32

  test "Compile full modular synth kernel in idiomatic Nim":
    const prog = compileDsp56300:
      while true:
        if (xMem[HDI08_HSR_ADDR] and 1) != 0:
          let cmd = xMem[HDI08_HORX_ADDR]
          let opcode = (cmd shr 16) and 0xFF
          let payload = (cmd shl 8) and 0xFFFFFF
          case opcode
          of 1:
            let raw16 = cmd and 0xFFFF
            if raw16 != 0:
              if raw16 < 128:
                xMem[X_PITCH_INC] = yMem[0x80 + raw16]
              else:
                xMem[X_PITCH_INC] = payload
            xMem[X_GATE] = 1
          of 2:
            xMem[X_GATE] = 0
          of 3:
            xMem[X_CUTOFF] = payload
          of 4:
            xMem[X_RESONANCE] = payload
          of 5:
            xMem[X_WAVEFORM] = cmd and 3
          of 6:
            xMem[X_ATTACK] = payload
          of 7:
            xMem[X_RELEASE] = payload
          of 8:
            xMem[X_MASTER_LEVEL] = payload

        # Phase accumulator
        let phase = (yMem[Y_OSC_PHASE] + xMem[X_PITCH_INC]) and 0xFFFFFF
        yMem[Y_OSC_PHASE] = phase

        # Waveform
        case xMem[X_WAVEFORM]
        of 0:
          yMem[Y_PREV_SAMPLE] = phase
        of 1:
          if phase >= 0:
            yMem[Y_PREV_SAMPLE] = 0x600000
          else:
            yMem[Y_PREV_SAMPLE] = 0xA00000
        of 2:
          yMem[Y_PREV_SAMPLE] = asl(abs24(phase) - 0x400000)
        else:
          let p2 = mpy(phase, phase)
          let p3 = mpy(phase, p2)
          yMem[Y_PREV_SAMPLE] = asl(phase - p3)

        # Envelope
        if xMem[X_GATE] != 0:
          let env = yMem[Y_ENV_LEVEL] + xMem[X_ATTACK]
          if env >= 0x7FFFFF:
            yMem[Y_ENV_LEVEL] = 0x7FFFFF
          else:
            yMem[Y_ENV_LEVEL] = env
        else:
          if yMem[Y_ENV_LEVEL] >= xMem[X_RELEASE]:
            yMem[Y_ENV_LEVEL] = yMem[Y_ENV_LEVEL] - xMem[X_RELEASE]
          else:
            yMem[Y_ENV_LEVEL] = 0

        # Filter
        let cut = xMem[X_CUTOFF]
        let fEff = asr(mpy(cut, cut))
        let q = 0x7FFFFF - xMem[X_RESONANCE]
        let high = yMem[Y_PREV_SAMPLE] - yMem[Y_FILT_LOW] - mpy(q, yMem[Y_FILT_BAND])
        yMem[Y_FILT_BAND] = mac(fEff, high, yMem[Y_FILT_BAND])
        yMem[Y_FILT_LOW] = mac(fEff, yMem[Y_FILT_BAND], yMem[Y_FILT_LOW])

        # VCA
        let vca = mpy(yMem[Y_FILT_LOW], yMem[Y_ENV_LEVEL])
        let scaled = mpy(vca, xMem[X_MASTER_LEVEL])
        xMem[ESAI_TX0_ADDR] = scaled
        xMem[X_AUDIO_OUT] = scaled

    check prog.len > 0
    check prog.len < 1024
