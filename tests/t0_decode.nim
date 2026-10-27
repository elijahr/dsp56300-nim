## Test suite for DSP56300 Instruction & Parallel Move Decoder
## Strict TDD: Red -> Green -> Fault-Plant

import std/unittest
import dsp56300/[decode_types, decode]

suite "DSP56300 Opcode & Parallel Move Decoder":
  test "Decode NOP":
    let inst = decodeInstruction([0x000000'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.aluOp == AluOp.opNop
    check inst.parallel.kind == ParallelMoveKind.pmNone

  test "Decode RTS and RTI":
    let rts = decodeInstruction([0x00000C'u32, 0'u32], 0x100'u32)
    check rts.words == 1
    check rts.ctrlOp == ControlOp.ctrlRts

    let rti = decodeInstruction([0x000004'u32, 0'u32], 0x100'u32)
    check rti.words == 1
    check rti.ctrlOp == ControlOp.ctrlRti

  test "Decode Parallel Move: Immediate Short (e.g. MOVE #$42, X0)":
    # Bits 23..21 = 001, ddddd = X0 (00100), imm8 = 0x42, opcode = 0x00 (NOP/MOVE)
    # Word: (0b001_00100 shl 16) or (0x42 shl 8) or 0x00 = 0x244200
    let inst = decodeInstruction([0x244200'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.aluOp == AluOp.opMove
    check inst.parallel.kind == ParallelMoveKind.pmImmediateShort
    check inst.parallel.immShort == 0x42'u32
    check inst.parallel.immDst == RegId.regX0

  test "Decode Parallel Move: Register to Register (e.g. MOVE X0, A)":
    # Bits 23..18 = 001000, eeeee = X0 (00100), ddddd = A (01110)
    # Word: (0b001000_00 shl 16) or (0b100_01110 shl 8) or 0x00 = 0x208E00
    let inst = decodeInstruction([0x208E00'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.parallel.kind == ParallelMoveKind.pmRegToReg
    check inst.parallel.regSrc == RegId.regX0
    check inst.parallel.regDst == RegId.regA

  test "Decode Parallel Move: Address Register Update (R2)+N2":
    # Bits 23..16 = 0x20
    # Bits 15..8 = 010_MM_RRR where MM = 01 ((Rn)+Nn), RRR = 010 (R2) -> 0b01001010 = 0x4A
    # Word: 0x204A00
    let inst = decodeInstruction([0x204A00'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.parallel.kind == ParallelMoveKind.pmAddrUpdate
    check inst.parallel.uReg == 2
    check inst.parallel.uMode == AddrMode.amPostIncN

  test "Decode Parallel Move: X Memory Move X:(R0)+, X0":
    # X:ea, D -> 01dd 0ddd W1MM MRRR (W=0 for read, M=011 for post-inc, R=0 for R0)
    # ddddd = X0 (00100) -> 0100 0100 = 0x44
    # Bits 15..8: W=0, 1, MM=011, RRR=000 -> 0101 1000 = 0x58
    # Opcode: 0x00
    let inst = decodeInstruction([0x445800'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.parallel.kind == ParallelMoveKind.pmXMem
    check inst.parallel.memSpace == MemSpace.memX
    check inst.parallel.isWrite == false
    check inst.parallel.memReg == RegId.regX0
    check inst.parallel.memMode == AddrMode.amPostInc
    check inst.parallel.memRNum == 0

  test "Decode Parallel Move: Dual X/Y Read X:(R0)+, X0  Y:(R4)+, Y0":
    # 1 w mm ee ff W rr MM RRR opcode
    # Bit 23=1, w=0 (read X), mm=11 ((R4)+), ee=00 (X0), ff=00 (Y0), W=0 (read Y), rr=00 (R4), MM=11 ((R0)+), RRR=000 (R0)
    # Bits 23..16: 1 0 11 00 00 = 0xB0
    # Bits 15..8: 0 00 11 000 = 0x18
    # Opcode: 0x00
    let inst = decodeInstruction([0xB01800'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.parallel.kind == ParallelMoveKind.pmXYDual
    check inst.parallel.xWrite == false
    check inst.parallel.xReg == RegId.regX0
    check inst.parallel.xMode == AddrMode.amPostInc
    check inst.parallel.xRNum == 0
    check inst.parallel.yWrite == false
    check inst.parallel.yReg == RegId.regY0
    check inst.parallel.yMode == AddrMode.amPostInc
    check inst.parallel.yRNum == 4

  test "Decode Parallel ALU: MPY X0, Y0, A with Dual Move":
    # Multiply: 1 QQQ d k2 k1 k0
    # QQQ for X0, Y0: Table 12-17 QQQ=101 (Y0, X0), d=0 (A), k2=0 (+), k1=0 (mpy only), k0=0 (no round)
    # Opcode = 1 101 0 000 = 0xD0 (MPY X0, Y0, A)
    # Combined with Dual Move above (0xB018D0)
    let inst = decodeInstruction([0xB018D0'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.aluOp == AluOp.opMpy
    check inst.dstReg == RegId.regA
    check inst.src1Reg == RegId.regY0
    check inst.src2Reg == RegId.regX0
    check inst.isNegMpy == false
    check inst.isRounded == false
    check inst.parallel.kind == ParallelMoveKind.pmXYDual

  test "Decode Conditional Move: IFcc.U NE":
    # Bits 23..16: 0x20
    # Bits 15..8: 0011 CCCC where CCCC = ccNE (0x2) -> 0x32
    # Opcode = 0x00
    let inst = decodeInstruction([0x203200'u32, 0'u32], 0x100'u32)
    check inst.words == 1
    check inst.parallel.kind == ParallelMoveKind.pmIfCc
    check inst.parallel.cc == ConditionCode.ccNE
    check inst.parallel.updateCcr == true

  test "Decode Control Flow: JMP Short and Long":
    # JMP xxx: 0000 1100 0000 aaaa aaaaaaaa -> 0x0C0123 (target: 0x123)
    let jmpShort = decodeInstruction([0x0C0123'u32, 0'u32], 0x100'u32)
    check jmpShort.words == 1
    check jmpShort.ctrlOp == ControlOp.ctrlJmp
    check jmpShort.targetAddr == 0x123'u32

    # JMP ea: 0000 1010 11MM MRRR 1000 0000 (absolute long ea: MM=110, RRR=000) -> 0x0AF080 with ext 0x4000
    let jmpLong = decodeInstruction([0x0AF080'u32, 0x4000'u32], 0x100'u32)
    check jmpLong.words == 2
    check jmpLong.ctrlOp == ControlOp.ctrlJmp
    check jmpLong.targetAddr == 0x4000'u32

  test "Decode Bit Manipulation: BSET, BCLR, BTST":
    # BSET #5, X:$12 (pp short): 0000 1010 10pp pppp 0S10 bbbb
    # S=0 (X), bit=5 (00101), pp=0x12
    # Bits 23..16: 0000 1010 = 0x0A
    # Bits 15..8: 10 010010 = 0x92
    # Bits 7..0: 0 0 1 0 0101 = 0x25
    let bset = decodeInstruction([0x0A9225'u32, 0'u32], 0x100'u32)
    check bset.words == 1
    check bset.bitOp == BitOpKind.bitSet
    check bset.bitNum == 5
    check bset.space == MemSpace.memX

  test "Decode Hardware Loops: DO and REP":
    # REP #32: 0000 0110 iiii iiii 1010 hhhh where i=0x20, h=0 -> 0x0620A0
    let rep = decodeInstruction([0x0620A0'u32, 0'u32], 0x100'u32)
    check rep.words == 1
    check rep.ctrlOp == ControlOp.ctrlRep
    check rep.immValue == 32

    # ENDDO: 0000 0000 0000 0000 1000 1100 = 0x00008C
    let enddo = decodeInstruction([0x00008C'u32, 0'u32], 0x100'u32)
    check enddo.words == 1
    check enddo.ctrlOp == ControlOp.ctrlEndDo
