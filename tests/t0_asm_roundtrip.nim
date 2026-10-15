## Tier T0 Test Suite: DSP56300 Assembler Round-Trip & Execution
## Verifies that instructions emitted by dsp56300/asm decode accurately
## and execute correctly on the cold-block IR runner.

import std/unittest
import dsp56300/[decode_types, decode, ir, runner]
import "dsp56300/asm.nim"



suite "DSP56300 Assembler Round-Trip & Execution":

  test "Round-trip System & Flow Control Encodings":
    # NOP
    let nopInst = decodeInstruction([asmNop()], 0)
    check nopInst.aluOp == AluOp.opNop

    # RTS
    let rtsInst = decodeInstruction([asmRts()], 0)
    check rtsInst.ctrlOp == ControlOp.ctrlRts

    # RTI
    let rtiInst = decodeInstruction([asmRti()], 0)
    check rtiInst.ctrlOp == ControlOp.ctrlRti

    # ENDDO
    let enddoInst = decodeInstruction([asmEndDo()], 0)
    check enddoInst.ctrlOp == ControlOp.ctrlEndDo

    # JMP short
    let jmpInst = decodeInstruction([asmJmp(0x150)], 0)
    check jmpInst.ctrlOp == ControlOp.ctrlJmp
    check jmpInst.targetAddr == 0x150

    # JSR short
    let jsrInst = decodeInstruction([asmJsr(0x220)], 0)
    check jsrInst.ctrlOp == ControlOp.ctrlJsr
    check jsrInst.targetAddr == 0x220

    # Jcc short
    let jccInst = decodeInstruction([asmJcc(ConditionCode.ccEQ, 0x350)], 0)
    check jccInst.ctrlOp == ControlOp.ctrlJcc
    check jccInst.cond == ConditionCode.ccEQ
    check jccInst.targetAddr == 0x350

  test "Round-trip Data ALU Encodings":
    # CLR A and CLR B
    let clrA = decodeInstruction([asmClr(RegId.regA)], 0)
    check clrA.aluOp == AluOp.opClr
    check clrA.dstReg == RegId.regA

    let clrB = decodeInstruction([asmClr(RegId.regB)], 0)
    check clrB.aluOp == AluOp.opClr
    check clrB.dstReg == RegId.regB

    # ADD X0, A and ADD Y0, B
    let addX0A = decodeInstruction([asmAdd(RegId.regX0, RegId.regA)], 0)
    check addX0A.aluOp == AluOp.opAdd
    check addX0A.src1Reg == RegId.regX0
    check addX0A.dstReg == RegId.regA

    let addY0B = decodeInstruction([asmAdd(RegId.regY0, RegId.regB)], 0)
    check addY0B.aluOp == AluOp.opAdd
    check addY0B.src1Reg == RegId.regY0
    check addY0B.dstReg == RegId.regB

    # SUB X1, A and SUB Y1, B
    let subX1A = decodeInstruction([asmSub(RegId.regX1, RegId.regA)], 0)
    check subX1A.aluOp == AluOp.opSub
    check subX1A.src1Reg == RegId.regX1
    check subX1A.dstReg == RegId.regA

    # MPY X0, Y0, A
    let mpyInst = decodeInstruction([asmMpy(RegId.regX0, RegId.regY0, RegId.regA)], 0)
    check mpyInst.aluOp == AluOp.opMpy
    check (mpyInst.src1Reg == RegId.regX0 and mpyInst.src2Reg == RegId.regY0) or
          (mpyInst.src1Reg == RegId.regY0 and mpyInst.src2Reg == RegId.regX0)
    check mpyInst.dstReg == RegId.regA

    # MAC X1, Y1, B
    let macInst = decodeInstruction([asmMac(RegId.regX1, RegId.regY1, RegId.regB)], 0)
    check macInst.aluOp == AluOp.opMac
    check (macInst.src1Reg == RegId.regX1 and macInst.src2Reg == RegId.regY1) or
          (macInst.src1Reg == RegId.regY1 and macInst.src2Reg == RegId.regX1)
    check macInst.dstReg == RegId.regB

    # MACR X0, Y1, A
    let macrInst = decodeInstruction([asmMacr(RegId.regX0, RegId.regY1, RegId.regA)], 0)
    check macrInst.aluOp == AluOp.opMacr
    check macrInst.dstReg == RegId.regA

    # Shifts & Negate
    let aslInst = decodeInstruction([asmAsl(RegId.regA)], 0)
    check aslInst.aluOp == AluOp.opAsl
    check aslInst.dstReg == RegId.regA

    let asrInst = decodeInstruction([asmAsr(RegId.regB)], 0)
    check asrInst.aluOp == AluOp.opAsr
    check asrInst.dstReg == RegId.regB

    let negInst = decodeInstruction([asmNeg(RegId.regA)], 0)
    check negInst.aluOp == AluOp.opNeg
    check negInst.dstReg == RegId.regA

    # TST A and TST B
    let tstA = decodeInstruction([asmTst(RegId.regA)], 0)
    check tstA.aluOp == AluOp.opTst
    check tstA.dstReg == RegId.regA

    let tstB = decodeInstruction([asmTst(RegId.regB)], 0)
    check tstB.aluOp == AluOp.opTst
    check tstB.dstReg == RegId.regB

  test "Round-trip Moves and Hardware Loops":
    # Register to Register move: MOVE X0, A1
    let movReg = decodeInstruction([asmMoveReg(RegId.regX0, RegId.regA1)], 0)
    check movReg.parallel.kind == ParallelMoveKind.pmRegToReg
    check movReg.parallel.regSrc == RegId.regX0
    check movReg.parallel.regDst == RegId.regA1

    # Short immediate move: MOVE #$42, X0
    let movImmShort = decodeInstruction([asmMoveImmShort(RegId.regX0, 0x42)], 0)
    check movImmShort.parallel.kind == ParallelMoveKind.pmImmediateShort
    check movImmShort.parallel.immDst == RegId.regX0
    check movImmShort.parallel.immShort == 0x42

    # Indirect memory move: MOVE X:(R0)+, X0
    let movIndX = decodeInstruction([asmMoveMemInd(MemSpace.memX, false, RegId.regX0, 0, AddrMode.amPostInc)], 0)
    check movIndX.parallel.kind == ParallelMoveKind.pmXMem
    check movIndX.parallel.isWrite == false
    check movIndX.parallel.memReg == RegId.regX0
    check movIndX.parallel.memRNum == 0
    check movIndX.parallel.memMode == AddrMode.amPostInc

    # Dual Parallel move: MPY X0, Y0, A  X:(R0)+, X0  Y:(R4)+, Y0
    let aluPart = asmMpy(RegId.regX0, RegId.regY0, RegId.regA)
    let dualInstWord = asmParallelXY(aluPart, RegId.regX0, 0, true, RegId.regY0, 4, true)
    let dualInst = decodeInstruction([dualInstWord], 0)
    check dualInst.aluOp == AluOp.opMpy
    check dualInst.parallel.kind == ParallelMoveKind.pmXYDual
    check dualInst.parallel.xReg == RegId.regX0
    check dualInst.parallel.xRNum == 0
    check dualInst.parallel.yReg == RegId.regY0
    check dualInst.parallel.yRNum == 4

    # DO Loop: DO #4, $102
    let doWords = asmDoImm(4, 0x000102)
    let doInst = decodeInstruction(doWords, 0x100)
    check doInst.ctrlOp == ControlOp.ctrlDo
    check doInst.immValue == 4
    check doInst.targetAddr == 0x000102

  test "Synthesized DSP Program Execution on Cold Runner":
    # Assemble a DSP accumulator accumulation loop:
    #   P:$100: DO #5, $102
    #   P:$102: ADD X0, A
    var state = newDspState()
    state.pc = 0x100'u32
    state.x0 = 0x000003'u32 # Step value = 3
    state.a1 = 0'u32

    let doInst = asmDoImm(5, 0x102)
    state.pRam[0x100] = doInst[0]
    state.pRam[0x101] = doInst[1]
    state.pRam[0x102] = asmAdd(RegId.regX0, RegId.regA)

    let blockIr = liftBasicBlock(state, 0x100'u32, maxWords = 3)
    let cycles = runBlock(state, blockIr)

    check cycles >= 5
    # Result: 3 * 5 = 15 (0x0F) in Accumulator A
    check state.a1 == 0x0F'u32
