# Clean-room MIT test suite for Motorola DSP56300 Hardware Loop Engine
# Hardware Reference: DSP56300FM Chapter 5, Chapter 12, Chapter 13

import unittest
import dsp56300/state
import dsp56300/loops

suite "DSP56300 Hardware Loop Engine":
  test "Basic DO Loop Execution and Normal Termination":
    var s: Dsp56300State
    s.reset()

    # Loop setup:
    # First instruction of loop is at $100
    # End of loop (expr) is at $103 -> LA will be $102
    # Count: 3 iterations
    let firstPc = 0x000100'u32
    let endExpr = 0x000103'u32
    let loopCount = 3'u32

    s.doStart(loopCount, endExpr, firstPc)

    check s.la == 0x000102'u32
    check s.lc == 3'u32
    check (s.sr and SR_LF) != 0 # Loop flag set
    check (s.sp and SP_CTR_MASK) == 2 # 2 levels pushed (LA:LC and PC:SR)

    # Iteration 1:
    # Execute through instructions $100, $101, $102
    s.checkEndOfLoop(0x000100'u32)
    s.checkEndOfLoop(0x000101'u32)
    s.checkEndOfLoop(0x000102'u32) # At LA!
    # Should decrement LC to 2 and loop back to $100
    check s.lc == 2'u32
    check s.pc == firstPc
    check (s.sr and SR_LF) != 0

    # Iteration 2:
    s.checkEndOfLoop(0x000100'u32)
    s.checkEndOfLoop(0x000101'u32)
    s.checkEndOfLoop(0x000102'u32)
    # Should decrement LC to 1 and loop back to $100
    check s.lc == 1'u32
    check s.pc == firstPc
    check (s.sr and SR_LF) != 0

    # Iteration 3 (final iteration):
    s.checkEndOfLoop(0x000100'u32)
    s.checkEndOfLoop(0x000101'u32)
    s.checkEndOfLoop(0x000102'u32)
    # LC == 1: Loop finishes! Stack pops twice, LF cleared, PC advances to $103 (expr)
    check (s.sr and SR_LF) == 0
    check s.pc == 0x000103'u32
    check (s.sp and SP_CTR_MASK) == 0 # Stack restored to level 0!

  test "Nested DO Loops (2-Level Nesting)":
    var s: Dsp56300State
    s.reset()

    # Outer loop: PC $100..$105 (LA = $105), count 2
    s.doStart(2'u32, 0x000106'u32, 0x000100'u32)
    check s.la == 0x000105'u32
    check s.lc == 2'u32
    check (s.sp and SP_CTR_MASK) == 2

    # Inner loop: PC $102..$104 (LA = $104), count 3
    s.doStart(3'u32, 0x000105'u32, 0x000102'u32)
    check s.la == 0x000104'u32
    check s.lc == 3'u32
    check (s.sp and SP_CTR_MASK) == 4 # 4 entries on stack

    # Inner loop iteration 1
    s.checkEndOfLoop(0x000104'u32)
    check s.lc == 2'u32
    check s.pc == 0x000102'u32

    # Inner loop iteration 2
    s.checkEndOfLoop(0x000104'u32)
    check s.lc == 1'u32
    check s.pc == 0x000102'u32

    # Inner loop iteration 3 (termination)
    s.checkEndOfLoop(0x000104'u32)
    # Inner loop terminates: outer loop LA ($105) and LC (2) restored!
    check s.la == 0x000105'u32
    check s.lc == 2'u32
    check (s.sp and SP_CTR_MASK) == 2
    check (s.sr and SR_LF) != 0 # Outer loop still active!

  test "DO Loop with Initial Count 0 (Skipped in Normal Mode)":
    var s: Dsp56300State
    s.reset()
    s.sr = s.sr and not SR_SC # Normal mode (SC = 0)

    # Initial count 0 skips loop immediately
    s.doStart(0'u32, 0x000105'u32, 0x000100'u32)
    check (s.sr and SR_LF) == 0
    check s.pc == 0x000105'u32 # Advanced to end address
    check (s.sp and SP_CTR_MASK) == 0 # Stack not left dirty

  test "DO FOREVER Loop and ENDDO Termination":
    var s: Dsp56300State
    s.reset()

    # DO FOREVER to end address $204 (LA = $203)
    s.doForeverStart(0x000204'u32, 0x000200'u32)
    check (s.sr and SR_LF) != 0
    check (s.sr and SR_FV) != 0

    # Iteration 1
    s.checkEndOfLoop(0x000203'u32)
    check s.pc == 0x000200'u32
    check (s.sr and SR_FV) != 0

    # Premature termination via ENDDO
    s.enddo()
    check (s.sr and SR_LF) == 0
    check (s.sr and SR_FV) == 0
    check (s.sp and SP_CTR_MASK) == 0

  test "Single-Instruction Repeat (REP)":
    var s: Dsp56300State
    s.reset()

    s.repStart(16'u32)
    check s.repActive == true
    check s.repCount == 16'u32
    check s.lc == 16'u32
    check (s.sp and SP_CTR_MASK) == 0 # No stack usage!
