## Tier T0 Test Suite: Motorola DSP56300 Assembly Text Parser & File Assembler
## Verifies that .asm text files are assembled into correct 24-bit DSP56300 machine code
## and execute with bit-accurate results on DspState.

import std/[unittest, tables, os]
import dsp56300/[ir, runner, state]
import dsp56300/asm_parser

suite "Motorola DSP56300 Assembly Text Parser & Assembler":

  test "Assemble basic ALU and control flow text":
    let source = """
      ; Simple accumulator addition test
      ORG P:$100
      CLR A
      MOVE #$05, X0
      ADD X0, A
      MOVE #$03, X1
      ADD X1, A
      RTS
    """
    let res = assembleText(source)
    check res.pRam.len == 6
    check res.pRam[0].address == 0x100'u32
    check res.pRam[1].address == 0x101'u32
    check res.pRam[2].address == 0x102'u32

    # Execute on DspState
    var st = newDspState()
    st.pc = 0x100'u32
    for e in res.pRam:
      st.pRam[e.address] = e.word

    let blk = liftBasicBlock(st, 0x100'u32, maxWords = 6)
    discard runBlock(st, blk)

    # Result: 0 + 5 + 3 = 8 in accumulator A1
    check st.a1 == 8'u32

  test "Assemble labels and conditional jumps":
    let source = """
      ORG P:$200
      CLR A
      MOVE #$04, B
      MOVE #$01, X0
    loop_top:
      ADD B, A
      SUB X0, B
      JNE loop_top
    loop_done:
      RTS
    """
    let res = assembleText(source)
    check "loop_top" in res.symbols
    check "loop_done" in res.symbols

    var st = newDspState()
    st.pc = 0x200'u32
    for e in res.pRam:
      st.pRam[e.address] = e.word

    # Run execution across multiple blocks until RTS
    for step in 0..<50:
      if st.pc >= 0x200'u32 and st.pRam[st.pc] == 0x00000C'u32: # RTS
        break
      let blk = liftBasicBlock(st, st.pc, maxWords = 10)
      discard runBlock(st, blk)

    # loop adds 4 + 3 + 2 + 1 = 10
    check st.a1 == 10'u32

  test "Assemble X and Y memory operands and constants":
    let source = """
      in_val  EQU $0010
      out_val EQU $0011
      coeff   EQU $0005

      ORG X:$0010
      DC $000020

      ORG Y:$0005
      DC $000003

      ORG P:$300
      MOVE X:in_val, X0
      MOVE Y:coeff, Y0
      MPY X0, Y0, A
      MOVE A, X:out_val
      RTS
    """
    let res = assembleText(source)
    check res.symbols["in_val"] == 0x0010'u32
    check res.symbols["out_val"] == 0x0011'u32
    check res.symbols["coeff"] == 0x0005'u32

    var st = newDspState()
    st.pc = 0x300'u32
    for e in res.pRam:
      st.pRam[e.address] = e.word
    for e in res.xRam:
      st.xRam[e.address] = e.word
    for e in res.yRam:
      st.yRam[e.address] = e.word

    # Verify initial memory constants were loaded
    check st.xRam[0x0010] == 0x000020'u32
    check st.yRam[0x0005] == 0x000003'u32

    # Run instructions
    for step in 0..<10:
      if st.pRam[st.pc] == 0x00000C'u32:
        break
      let blk = liftBasicBlock(st, st.pc, maxWords = 4)
      discard runBlock(st, blk)

    # MPY in fractional DSP56300: 0x000020 * 0x000003
    check st.x0 == 0x000020'u32
    check st.y0 == 0x000003'u32

  test "Assemble file from disk":
    let tmpFile = getTempDir() / "test_module.asm"
    writeFile(tmpFile, """
      ORG P:$400
      CLR B
      MOVE #$15, Y0
      ADD Y0, B
      RTS
    """)
    let res = assembleFile(tmpFile)
    removeFile(tmpFile)

    check res.pRam.len == 4
    var st = newDspState()
    st.pc = 0x400'u32
    for e in res.pRam:
      st.pRam[e.address] = e.word
    let blk = liftBasicBlock(st, 0x400'u32, maxWords = 4)
    discard runBlock(st, blk)
    check st.b1 == 0x15'u32

  test "End-to-end assemble and execute Omni DSP56300 kernel":
    let omniAsm = """
; Generated from Omni DSL
in1                 EQU     $0000
out1                EQU     $0010
freq                EQU     $0020
phase               EQU     $0000
freq_incr           EQU     $0040

                ORG     X:$0020
                DC      $012C5F         ; freq = 440.0

                ORG     Y:$0000
                DC      $000000         ; phase = 0.0

                ORG     P:$0100
OmniSine_process:
                MOVE    X:freq, A
                MOVE    A, Y:freq_incr

                MOVE    Y:phase, X0
                MOVE    X0, A
                MPY     X0, X0, B
                MOVE    B, Y0
                MOVE    #$155555, Y1
                MPY     -Y0, Y1, B
                MOVE    #$400000, Y1
                ADD     Y1, B
                MOVE    B, Y1
                MPY     X0, Y1, A
                MOVE    A, X:out1

                MOVE    Y:phase, A
                MOVE    Y:freq_incr, X0
                ADD     X0, A
                MOVE    #$7FFFFF, X0
                AND     X0, A
                MOVE    A, Y:phase
                RTS
    """
    let res = assembleText(omniAsm)
    check res.symbols["freq"] == 0x0020'u32
    check res.symbols["out1"] == 0x0010'u32
    check res.symbols["phase"] == 0x0000'u32
    check res.symbols["freq_incr"] == 0x0040'u32

    var st = newDspState()
    st.pc = 0x100'u32
    for e in res.pRam:
      st.pRam[e.address] = e.word
    for e in res.xRam:
      st.xRam[e.address] = e.word
    for e in res.yRam:
      st.yRam[e.address] = e.word

    # Run kernel until RTS
    for step in 0..<30:
      if st.pRam[st.pc] == 0x00000C'u32: # RTS
        break
      let blk = liftBasicBlock(st, st.pc, maxWords = 4)
      discard runBlock(st, blk)

    # Verify kernel updated phase and computed freq_incr
    check st.yRam[0x0040] == 0x012C5F'u32 # freq_incr written to Y:$0040
    check st.yRam[0x0000] == 0x012C5F'u32 # phase updated in Y:$0000

