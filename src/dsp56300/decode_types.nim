## Clean-room MIT Motorola DSP56300 / DSP56311 Instruction Decoder Types
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

type
  RegId* {.pure.} = enum
    regNone
    # Data ALU 24-bit input registers
    regX0, regX1, regY0, regY1
    # Data ALU accumulator slices
    regA0, regA1, regA2
    regB0, regB1, regB2
    # Data ALU 56-bit accumulator composites
    regA, regB
    # Long move accumulator / register pairs
    regA10, regB10, regX, regY, regAB, regBA
    # AGU 24-bit address registers
    regR0, regR1, regR2, regR3, regR4, regR5, regR6, regR7
    # AGU 24-bit offset registers
    regN0, regN1, regN2, regN3, regN4, regN5, regN6, regN7
    # AGU 24-bit modifier registers
    regM0, regM1, regM2, regM3, regM4, regM5, regM6, regM7
    # AGU extension pointer
    regEP
    # Program Controller registers
    regPC, regSR, regOMR, regSP, regSSH, regSSL, regLA, regLC
    regVBA, regSC, regSZ

  MemSpace* {.pure.} = enum
    memX
    memY
    memP
    memL

  AddrMode* {.pure.} = enum
    amPostIncN       ## (Rn)+Nn
    amPostDecN       ## (Rn)-Nn
    amPostInc        ## (Rn)+
    amPostDec        ## (Rn)-
    amNoUpdate       ## (Rn)
    amIndexedNoUpdate## (Rn+Nn)
    amPreDec         ## -(Rn)
    amAbsolute       ## Absolute address (ea long or short aa)
    amImmediate      ## Immediate short or long
    amRegDirect      ## Direct register reference

  ConditionCode* {.pure.} = enum
    ccHS = 0x0 ## Carry Clear / Higher or Same (C=0)
    ccGE = 0x1 ## Greater or Equal (N ^ V = 0)
    ccNE = 0x2 ## Not Equal (Z=0)
    ccPL = 0x3 ## Plus (N=0)
    ccNN = 0x4 ## Not Normalized (Z + (U & not E) = 0)
    ccEC = 0x5 ## Extension Clear (E=0)
    ccLC = 0x6 ## Limit Clear (L=0)
    ccGT = 0x7 ## Greater Than (Z + (N ^ V) = 0)
    ccLO = 0x8 ## Carry Set / Lower (C=1)
    ccLT = 0x9 ## Less Than (N ^ V = 1)
    ccEQ = 0xA ## Equal (Z=1)
    ccMI = 0xB ## Minus (N=1)
    ccNR = 0xC ## Normalized (Z + (U & not E) = 1)
    ccES = 0xD ## Extension Set (E=1)
    ccLS = 0xE ## Limit Set (L=1)
    ccLE = 0xF ## Less or Equal (Z + (N ^ V) = 1)

  AluOp* {.pure.} = enum
    opNop
    opMove
    opAdd, opSub, opAdc, opSbc
    opMac, opMacr, opMpy, opMpyr
    opNeg, opAbs, opClr, opRnd, opTfr, opTst
    opCmp, opCmpm, opCmpu
    opAnd, opOr, opEor, opNot
    opAsl, opAsr, opLsl, opLsr, opRol, opRor
    opAddr, opAddl, opSubr, opSubl
    opDiv, opNorm, opNormf, opClb, opMax, opMaxm
    opMerge, opInc, opDec

  ParallelMoveKind* {.pure.} = enum
    pmNone
    pmImmediateShort
    pmRegToReg
    pmAddrUpdate
    pmXMem
    pmYMem
    pmLMem
    pmXYDual
    pmXR_ClassI, pmXR_ClassII
    pmRY_ClassI, pmRY_ClassII
    pmIfCc

  ParallelMove* = object
    case kind*: ParallelMoveKind
    of pmNone:
      discard
    of pmImmediateShort:
      immShort*: uint32
      immDst*: RegId
    of pmRegToReg:
      regSrc*: RegId
      regDst*: RegId
    of pmAddrUpdate:
      uMode*: AddrMode
      uReg*: uint8 ## R0..R7
    of pmXMem, pmYMem, pmLMem:
      memSpace*: MemSpace
      isWrite*: bool
      memReg*: RegId
      memMode*: AddrMode
      memRNum*: uint8
      memAddr*: uint32 ## Short absolute aa, or Rn+xxx
    of pmXYDual:
      xWrite*: bool
      xReg*: RegId
      xMode*: AddrMode
      xRNum*: uint8
      yWrite*: bool
      yReg*: RegId
      yMode*: AddrMode
      yRNum*: uint8
    of pmXR_ClassI:
      xrWrite*: bool
      xrXReg*: RegId
      xrMode*: AddrMode
      xrRNum*: uint8
      xrR2Src*: RegId
      xrR2Dst*: RegId
    of pmXR_ClassII:
      xr2Acc*: RegId ## A or B
      xr2Mode*: AddrMode
      xr2RNum*: uint8
    of pmRY_ClassI:
      ryWrite*: bool
      ryYReg*: RegId
      ryMode*: AddrMode
      ryRNum*: uint8
      ryR1Src*: RegId
      ryR1Dst*: RegId
    of pmRY_ClassII:
      ry2Acc*: RegId ## A or B
      ry2Mode*: AddrMode
      ry2RNum*: uint8
    of pmIfCc:
      cc*: ConditionCode
      updateCcr*: bool

  ControlOp* {.pure.} = enum
    ctrlNone
    ctrlJmp, ctrlJsr, ctrlJcc, ctrlJscc
    ctrlBra, ctrlBsr, ctrlBcc, ctrlBscc
    ctrlRts, ctrlRti
    ctrlDo, ctrlDor, ctrlDoForever, ctrlEndDo, ctrlBrkCc, ctrlRep
    ctrlTrap, ctrlTrapCc, ctrlDebug, ctrlDebugCc
    ctrlStop, ctrlWait, ctrlReset, ctrlIllegal

  BitOpKind* {.pure.} = enum
    bitNone
    bitSet, bitClr, bitChg, bitTst
    bitJclr, bitJset, bitJsclr, bitJsset
    bitBrclr, bitBrset, bitBsclr, bitBsset

  MoveSpecialKind* {.pure.} = enum
    msNone
    msMoveC, msMoveM, msMoveP

  Instruction* = object
    words*: uint8 ## 1 or 2 words
    cycles*: uint8
    aluOp*: AluOp
    dstReg*: RegId
    src1Reg*: RegId
    src2Reg*: RegId
    isNegMpy*: bool
    isRounded*: bool
    isSu*: bool ## Signed * Unsigned
    isUu*: bool ## Unsigned * Unsigned
    parallel*: ParallelMove
    ctrlOp*: ControlOp
    cond*: ConditionCode
    bitOp*: BitOpKind
    bitNum*: uint8
    moveSpecial*: MoveSpecialKind
    immValue*: uint32
    targetAddr*: uint32
    targetReg*: RegId
    space*: MemSpace
    mode*: AddrMode
    rNum*: uint8
    isWrite*: bool
    pAddr*: uint32
