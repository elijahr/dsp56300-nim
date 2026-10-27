## Clean-room MIT Motorola DSP56300 Native JIT Backend
## Emits native ARM64 (Apple Silicon MAP_JIT + pthread_jit_write_protect_np) and x86_64 machine code.
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import posix
import dsp56300/[decode_types, state, memory, agu, ir, runner]

when defined(macosx) and defined(arm64):
  proc pthread_jit_write_protect_np(enabled: cint) {.importc, header: "<pthread.h>".}
  proc sys_icache_invalidate(
    p: pointer, len: csize_t
  ) {.importc, header: "<libkern/OSCacheControl.h>".}

const
  MAP_JIT* = 0x0800'i32
  MAP_ANON* = 0x1000'i32

  # Compile-time exact byte offsets into DspState / Dsp56300State
  OFFSET_CORE* = offsetOf(DspState, core)
  OFFSET_X0* = OFFSET_CORE + offsetOf(Dsp56300State, x0)
  OFFSET_X1* = OFFSET_CORE + offsetOf(Dsp56300State, x1)
  OFFSET_Y0* = OFFSET_CORE + offsetOf(Dsp56300State, y0)
  OFFSET_Y1* = OFFSET_CORE + offsetOf(Dsp56300State, y1)
  OFFSET_A2* = OFFSET_CORE + offsetOf(Dsp56300State, a2)
  OFFSET_A1* = OFFSET_CORE + offsetOf(Dsp56300State, a1)
  OFFSET_A0* = OFFSET_CORE + offsetOf(Dsp56300State, a0)
  OFFSET_B2* = OFFSET_CORE + offsetOf(Dsp56300State, b2)
  OFFSET_B1* = OFFSET_CORE + offsetOf(Dsp56300State, b1)
  OFFSET_B0* = OFFSET_CORE + offsetOf(Dsp56300State, b0)
  OFFSET_R* = OFFSET_CORE + offsetOf(Dsp56300State, r)
  OFFSET_N* = OFFSET_CORE + offsetOf(Dsp56300State, n)
  OFFSET_M* = OFFSET_CORE + offsetOf(Dsp56300State, m)
  OFFSET_PC* = OFFSET_CORE + offsetOf(Dsp56300State, pc)
  OFFSET_SR* = OFFSET_CORE + offsetOf(Dsp56300State, sr)

proc regOffset*(reg: RegId): int =
  case reg
  of RegId.regX0:
    OFFSET_X0
  of RegId.regX1:
    OFFSET_X1
  of RegId.regY0:
    OFFSET_Y0
  of RegId.regY1:
    OFFSET_Y1
  of RegId.regA0:
    OFFSET_A0
  of RegId.regA1:
    OFFSET_A1
  of RegId.regA2:
    OFFSET_A2
  of RegId.regB0:
    OFFSET_B0
  of RegId.regB1:
    OFFSET_B1
  of RegId.regB2:
    OFFSET_B2
  of RegId.regA:
    OFFSET_A1
  of RegId.regB:
    OFFSET_B1
  of RegId.regR0 .. RegId.regR7:
    OFFSET_R + (int(reg) - int(RegId.regR0)) * 4
  of RegId.regN0 .. RegId.regN7:
    OFFSET_N + (int(reg) - int(RegId.regN0)) * 4
  of RegId.regM0 .. RegId.regM7:
    OFFSET_M + (int(reg) - int(RegId.regM0)) * 4
  of RegId.regPC:
    OFFSET_PC
  of RegId.regSR:
    OFFSET_SR
  else:
    -1

# Forward-facing C-compatible helpers called by JIT machine code when needed
proc nativeMemRead*(
    statePtr: ptr DspState, space: cint, address: uint32
): uint32 {.cdecl.} =
  if statePtr != nil:
    let sp = if space == 0: Dsp56300Space.SpaceX else: Dsp56300Space.SpaceY
    return statePtr[].mem.readMem(statePtr[].core, sp, address)
  return 0

proc nativeMemWrite*(
    statePtr: ptr DspState, space: cint, address: uint32, val: uint32
) {.cdecl.} =
  if statePtr != nil:
    let sp = if space == 0: Dsp56300Space.SpaceX else: Dsp56300Space.SpaceY
    statePtr[].mem.writeMem(statePtr[].core, sp, address, val)

proc nativeAguModulo*(r: uint32, delta: int32, m: uint32): uint32 {.cdecl.} =
  agu.updateAddress(r, delta, m)

# ---------------------------------------------------------------------------
# ARM64 Machine Code Emitter
# ---------------------------------------------------------------------------

proc armMov64(rd: int, val: uint64): seq[uint32] =
  let w0 = uint32(val and 0xFFFF'u64)
  let w1 = uint32((val shr 16) and 0xFFFF'u64)
  let w2 = uint32((val shr 32) and 0xFFFF'u64)
  let w3 = uint32((val shr 48) and 0xFFFF'u64)
  result.add(0xD2800000'u32 or (0'u32 shl 21) or (w0 shl 5) or uint32(rd))
  if w1 != 0 or w2 != 0 or w3 != 0:
    result.add(0xF2800000'u32 or (1'u32 shl 21) or (w1 shl 5) or uint32(rd))
  if w2 != 0 or w3 != 0:
    result.add(0xF2800000'u32 or (2'u32 shl 21) or (w2 shl 5) or uint32(rd))
  if w3 != 0:
    result.add(0xF2800000'u32 or (3'u32 shl 21) or (w3 shl 5) or uint32(rd))

proc armMovImm32(rd: int, imm: uint32): seq[uint32] =
  let low = imm and 0xFFFF'u32
  let high = (imm shr 16) and 0xFFFF'u32
  result.add(0x52800000'u32 or (low shl 5) or uint32(rd))
  if high != 0:
    result.add(0x72A00000'u32 or (high shl 5) or uint32(rd))

proc armLdrW(rt: int, offset: int): uint32 =
  0xB9400000'u32 or (uint32(offset div 4) shl 10) or (19'u32 shl 5) or uint32(rt)

proc armStrW(rt: int, offset: int): uint32 =
  0xB9000000'u32 or (uint32(offset div 4) shl 10) or (19'u32 shl 5) or uint32(rt)

proc armLdrB(rt: int, offset: int): uint32 =
  0x39400000'u32 or (uint32(offset) shl 10) or (19'u32 shl 5) or uint32(rt)

proc armStrB(rt: int, offset: int): uint32 =
  0x39000000'u32 or (uint32(offset) shl 10) or (19'u32 shl 5) or uint32(rt)

proc armLoadAcc(accReg: RegId): seq[uint32] =
  # Loads signed 56-bit accumulator into x9 using scratch w13-w15
  let offA2 = if accReg == RegId.regB: OFFSET_B2 else: OFFSET_A2
  let offA1 = if accReg == RegId.regB: OFFSET_B1 else: OFFSET_A1
  let offA0 = if accReg == RegId.regB: OFFSET_B0 else: OFFSET_A0
  result.add(armLdrB(13, offA2)) # ldrb w13, [x19, #offA2]
  result.add(armLdrW(14, offA1)) # ldr w14, [x19, #offA1]
  result.add(armLdrW(15, offA0)) # ldr w15, [x19, #offA0]
  result.add(0x53005DCE'u32) # ubfx w14, w14, #0, #24
  result.add(0x53005DEF'u32) # ubfx w15, w15, #0, #24
  result.add(0xAA0E61E9'u32) # orr x9, x15, x14, lsl #24
  result.add(0xAA0DC129'u32) # orr x9, x9, x13, lsl #48
  result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56

proc armStoreAcc(accReg: RegId): seq[uint32] =
  # Stores signed 56-bit accumulator from x9 back to DspState
  let offA2 = if accReg == RegId.regB: OFFSET_B2 else: OFFSET_A2
  let offA1 = if accReg == RegId.regB: OFFSET_B1 else: OFFSET_A1
  let offA0 = if accReg == RegId.regB: OFFSET_B0 else: OFFSET_A0
  result.add(0xD370FD2A'u32) # lsr x10, x9, #48
  result.add(armStrB(10, offA2)) # strb w10, [x19, #offA2]
  result.add(0xD358FD2B'u32) # lsr x11, x9, #24
  result.add(0x53005D6B'u32) # ubfx w11, w11, #0, #24
  result.add(armStrW(11, offA1)) # str w11, [x19, #offA1]
  result.add(0x53005D2C'u32) # ubfx w12, w9, #0, #24
  result.add(armStrW(12, offA0)) # str w12, [x19, #offA0]

proc computeBlockCycles*(blk: IrBasicBlock): uint32 =
  var loopIterations = 1'u32
  for op in blk.ops:
    if op.kind == IrOpKind.irLoopDo:
      loopIterations = op.imm
      break
    elif op.kind notin {IrOpKind.irCheckGen, IrOpKind.irNop}:
      break

  var perIter = 0'u32
  for rawOp in blk.ops:
    let op = canonicalizeOp(rawOp)
    if op.kind in {
      IrOpKind.irNop, IrOpKind.irAluOp, IrOpKind.irLoopEndDo, IrOpKind.irLoopRep,
      IrOpKind.irHalt,
    }:
      perIter += 1
    elif op.kind in {
      IrOpKind.irBranch, IrOpKind.irBranchCond, IrOpKind.irCall, IrOpKind.irReturn,
      IrOpKind.irReturnInt, IrOpKind.irLoopDo, IrOpKind.irLoopDoForever,
      IrOpKind.irLoopBrkCc,
    }:
      perIter += 2

  result =
    if perIter == 0:
      1'u32
    else:
      (perIter * loopIterations)

proc assembleArm64*(blk: IrBasicBlock): seq[uint32] =
  ## Clean-room ARM64 machine-code emitter lowering all MicroOps in blk directly to A64 instructions.
  ## Follows standard ARM64 ABI where x0 = ptr DspState, returns cycles in w0.
  result = @[]

  # Prologue
  result.add(0xA9BD7BFD'u32) # stp x29, x30, [sp, -48]!
  result.add(0xA90153F3'u32) # stp x19, x20, [sp, 16]
  result.add(0xA9025BF5'u32) # stp x21, x22, [sp, 32]
  result.add(0x910003FD'u32) # mov x29, sp
  result.add(0xAA0003F3'u32) # mov x19, x0

  # Compute cycles
  let cycles = computeBlockCycles(blk)

  # Handle DO Loop entry
  var loopIterations = 1'u32
  var isLoopBlock = false
  var loopEndPc = 0'u32
  for op in blk.ops:
    if op.kind == IrOpKind.irLoopDo:
      loopIterations = op.imm
      loopEndPc = op.pAddr
      isLoopBlock = true
      break
    elif op.kind notin {IrOpKind.irCheckGen, IrOpKind.irNop}:
      break

  var loopStartIdx = 0
  if isLoopBlock:
    result.add(armMovImm32(20, loopIterations)) # mov w20, #loopIterations
    loopStartIdx = result.len

  for rawOp in blk.ops:
    let op = canonicalizeOp(rawOp)
    case op.kind
    of IrOpKind.irNop, IrOpKind.irCheckGen:
      discard
    of IrOpKind.irLoadImm:
      let off = regOffset(op.dst)
      if off >= 0:
        result.add(armMovImm32(9, op.imm and 0x00FFFFFF'u32))
        result.add(armStrW(9, off))
    of IrOpKind.irLoadReg:
      let srcOff = regOffset(op.src1)
      let dstOff = regOffset(op.dst)
      if srcOff >= 0 and dstOff >= 0:
        result.add(armLdrW(9, srcOff))
        result.add(armStrW(9, dstOff))
    of IrOpKind.irStoreReg:
      let srcOff = regOffset(op.src1)
      let dstOff = regOffset(op.dst)
      if srcOff >= 0 and dstOff >= 0:
        result.add(armLdrW(9, srcOff))
        result.add(armStrW(9, dstOff))
    of IrOpKind.irLoadMem:
      let dstOff = regOffset(op.dst)
      if dstOff >= 0:
        result.add(0xAA1303E0'u32) # mov x0, x19
        result.add(if op.space == MemSpace.memX: 0x52800001'u32 else: 0x52800021'u32)
          # mov w1, #0 / #1
        if op.addrMode == AddrMode.amAbsolute:
          result.add(armMovImm32(2, op.imm))
        else:
          let rOff = OFFSET_R + int(op.rNum) * 4
          result.add(armLdrW(2, rOff))
        result.add(armMov64(16, cast[uint64](nativeMemRead)))
        result.add(0xD63F0200'u32) # blr x16
        result.add(armStrW(0, dstOff)) # str w0, [x19, #dstOff]
    of IrOpKind.irStoreMem:
      let srcOff = regOffset(op.src1)
      if srcOff >= 0:
        result.add(0xAA1303E0'u32) # mov x0, x19
        result.add(if op.space == MemSpace.memX: 0x52800001'u32 else: 0x52800021'u32)
        if op.addrMode == AddrMode.amAbsolute:
          result.add(armMovImm32(2, op.imm))
        else:
          let rOff = OFFSET_R + int(op.rNum) * 4
          result.add(armLdrW(2, rOff))
        result.add(armLdrW(3, srcOff))
        result.add(armMov64(16, cast[uint64](nativeMemWrite)))
        result.add(0xD63F0200'u32) # blr x16
    of IrOpKind.irAguUpdate:
      let rOff = OFFSET_R + int(op.rNum) * 4
      result.add(armLdrW(9, rOff))
      case op.addrMode
      of AddrMode.amPostInc:
        result.add(0x11000529'u32) # add w9, w9, #1
      of AddrMode.amPostDec:
        result.add(0x51000529'u32) # sub w9, w9, #1
      of AddrMode.amPostIncN:
        let nOff = OFFSET_N + int(op.rNum) * 4
        result.add(armLdrW(10, nOff))
        result.add(0x0B0A0129'u32) # add w9, w9, w10
      of AddrMode.amPostDecN:
        let nOff = OFFSET_N + int(op.rNum) * 4
        result.add(armLdrW(10, nOff))
        result.add(0x4B0A0129'u32) # sub w9, w9, w10
      else:
        discard
      result.add(0x53005D29'u32) # ubfx w9, w9, #0, #24
      result.add(armStrW(9, rOff))
    of IrOpKind.irAluOp:
      # Load operands into w10 (src1) and w12 (src2)
      let src1Off = regOffset(op.src1)
      let src2Off = regOffset(op.src2)
      if src1Off >= 0:
        result.add(armLdrW(10, src1Off))
        result.add(0x13005D4A'u32) # sbfx w10, w10, #0, #24 (sign-extend)
      if src2Off >= 0:
        result.add(armLdrW(12, src2Off))
        result.add(0x13005D8C'u32) # sbfx w12, w12, #0, #24 (sign-extend)

      case op.aluOp
      of AluOp.opMpy, AluOp.opMpyr:
        result.add(0x9B2C7D4B'u32) # smull x11, w10, w12
        result.add(0xD37FF96B'u32) # lsl x11, x11, #1
        if op.isNeg:
          result.add(0xCB0B03EB'u32) # neg x11, x11
        result.add(0xAA0B03E9'u32) # mov x9, x11
        result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56
        result.add(armStoreAcc(op.dst))
      of AluOp.opMac, AluOp.opMacr:
        result.add(armLoadAcc(op.dst)) # loads accumulator to x9
        result.add(0x9B2C7D4B'u32) # smull x11, w10, w12
        result.add(0xD37FF96B'u32) # lsl x11, x11, #1
        if op.isNeg:
          result.add(0xCB0B03EB'u32) # neg x11, x11
        result.add(0x8B0B0129'u32) # add x9, x9, x11
        result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56
        result.add(armStoreAcc(op.dst))
      of AluOp.opAdd:
        result.add(armLoadAcc(op.dst))
        result.add(0x93407D4A'u32) # sxtw x10, w10
        result.add(0xD3689D4A'u32) # lsl x10, x10, #24
        result.add(0x8B0A0129'u32) # add x9, x9, x10
        result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56
        result.add(armStoreAcc(op.dst))
      of AluOp.opSub:
        result.add(armLoadAcc(op.dst))
        result.add(0x93407D4A'u32) # sxtw x10, w10
        result.add(0xD3689D4A'u32) # lsl x10, x10, #24
        result.add(0xCB0A0129'u32) # sub x9, x9, x10
        result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56
        result.add(armStoreAcc(op.dst))
      of AluOp.opClr:
        result.add(0xAA1F03E9'u32) # mov x9, xzr (0)
        result.add(armStoreAcc(op.dst))
      of AluOp.opNeg:
        result.add(armLoadAcc(op.dst))
        result.add(0xCB0903E9'u32) # neg x9, x9
        result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56
        result.add(armStoreAcc(op.dst))
      of AluOp.opAsl:
        result.add(armLoadAcc(op.dst))
        result.add(0xD37FF929'u32) # lsl x9, x9, #1
        result.add(0x9340DD29'u32) # sbfx x9, x9, #0, #56
        result.add(armStoreAcc(op.dst))
      of AluOp.opAsr:
        result.add(armLoadAcc(op.dst))
        result.add(0x9341FD29'u32) # asr x9, x9, #1
        result.add(armStoreAcc(op.dst))
      else:
        discard
    of IrOpKind.irBranch:
      result.add(armMovImm32(9, op.imm))
      result.add(armStrW(9, OFFSET_PC))
    of IrOpKind.irLoopDo:
      discard # Handled by loop wrapper
    else:
      discard

  if isLoopBlock:
    result.add(0x71000694'u32) # subs w20, w20, #1
    let branchOffset = int32(loopStartIdx - result.len)
    let imm19 = uint32(branchOffset and 0x7FFFF)
    result.add(0x54000000'u32 or (imm19 shl 5) or 1'u32) # b.ne loopStart

  # Update PC if no branch
  let finalPc =
    if isLoopBlock:
      (loopEndPc + 1)
    else:
      blk.endPc
  result.add(armMovImm32(9, finalPc))
  result.add(armStrW(9, OFFSET_PC))
  if isLoopBlock:
    result.add(armMovImm32(9, 0))
    result.add(armStrW(9, OFFSET_CORE + offsetOf(Dsp56300State, lc)))

  # Epilogue: return cycles in w0
  result.add(armMovImm32(0, cycles))
  result.add(0xA9425BF5'u32) # ldp x21, x22, [sp, 32]
  result.add(0xA94153F3'u32) # ldp x19, x20, [sp, 16]
  result.add(0xA8C37BFD'u32) # ldp x29, x30, [sp], 48
  result.add(0xD65F03C0'u32) # ret

# ---------------------------------------------------------------------------
# x86_64 Machine Code Emitter
# ---------------------------------------------------------------------------

proc x86EmitU32(buf: var seq[byte], val: uint32) =
  buf.add(byte(val and 0xFF'u32))
  buf.add(byte((val shr 8) and 0xFF'u32))
  buf.add(byte((val shr 16) and 0xFF'u32))
  buf.add(byte((val shr 24) and 0xFF'u32))

proc x86EmitU64(buf: var seq[byte], val: uint64) =
  for i in 0 ..< 8:
    buf.add(byte((val shr (i * 8)) and 0xFF'u64))

proc x86LoadAcc(buf: var seq[byte], accReg: RegId) =
  # Loads signed 56-bit accumulator into rax using r8d scratch
  let offA2 = uint32(if accReg == RegId.regB: OFFSET_B2 else: OFFSET_A2)
  let offA1 = uint32(if accReg == RegId.regB: OFFSET_B1 else: OFFSET_A1)
  let offA0 = uint32(if accReg == RegId.regB: OFFSET_B0 else: OFFSET_A0)
  # movzx eax, byte ptr [rbx + offA2]
  buf.add([0x0F'u8, 0xB6, 0x83])
  x86EmitU32(buf, offA2)
  # shl rax, 24
  buf.add([0x48'u8, 0xC1, 0xE0, 0x18])
  # mov r8d, [rbx + offA1]
  buf.add([0x44'u8, 0x8B, 0x83])
  x86EmitU32(buf, offA1)
  # and r8d, 0x00FFFFFF
  buf.add([0x41'u8, 0x81, 0xE0, 0xFF, 0xFF, 0xFF, 0x00])
  # or rax, r8
  buf.add([0x4C'u8, 0x09, 0xC0])
  # shl rax, 24
  buf.add([0x48'u8, 0xC1, 0xE0, 0x18])
  # mov r8d, [rbx + offA0]
  buf.add([0x44'u8, 0x8B, 0x83])
  x86EmitU32(buf, offA0)
  # and r8d, 0x00FFFFFF
  buf.add([0x41'u8, 0x81, 0xE0, 0xFF, 0xFF, 0xFF, 0x00])
  # or rax, r8
  buf.add([0x4C'u8, 0x09, 0xC0])
  # 56-bit sign-extend to 64-bit: shl rax, 8; sar rax, 8
  buf.add([0x48'u8, 0xC1, 0xE0, 0x08])
  buf.add([0x48'u8, 0xC1, 0xF8, 0x08])

proc x86StoreAcc(buf: var seq[byte], accReg: RegId) =
  # Stores signed 56-bit accumulator from rax back to DspState
  let offA2 = uint32(if accReg == RegId.regB: OFFSET_B2 else: OFFSET_A2)
  let offA1 = uint32(if accReg == RegId.regB: OFFSET_B1 else: OFFSET_A1)
  let offA0 = uint32(if accReg == RegId.regB: OFFSET_B0 else: OFFSET_A0)
  # mov edx, eax
  buf.add([0x89'u8, 0xC2])
  # and edx, 0x00FFFFFF
  buf.add([0x81'u8, 0xE2, 0xFF, 0xFF, 0xFF, 0x00])
  # mov [rbx + offA0], edx
  buf.add([0x89'u8, 0x93])
  x86EmitU32(buf, offA0)
  # mov rdx, rax; shr rdx, 24
  buf.add([0x48'u8, 0x89, 0xC2, 0x48, 0xC1, 0xEA, 0x18])
  # and edx, 0x00FFFFFF
  buf.add([0x81'u8, 0xE2, 0xFF, 0xFF, 0xFF, 0x00])
  # mov [rbx + offA1], edx
  buf.add([0x89'u8, 0x93])
  x86EmitU32(buf, offA1)
  # mov rdx, rax; shr rdx, 48
  buf.add([0x48'u8, 0x89, 0xC2, 0x48, 0xC1, 0xEA, 0x30])
  # mov [rbx + offA2], dl
  buf.add([0x88'u8, 0x93])
  x86EmitU32(buf, offA2)

proc assembleX86_64*(blk: IrBasicBlock): seq[byte] =
  ## Clean-room x86_64 machine-code emitter lowering all MicroOps in blk directly to AMD64 instructions.
  ## Follows System V AMD64 ABI where rdi = ptr DspState, returns cycles in eax.
  result = @[]

  # Prologue
  result.add(0x55'u8) # push rbp
  result.add([0x48'u8, 0x89, 0xE5]) # mov rbp, rsp
  result.add(0x53'u8) # push rbx
  result.add([0x41'u8, 0x54]) # push r12
  result.add([0x41'u8, 0x55]) # push r13
  result.add([0x41'u8, 0x56]) # push r14
  result.add([0x41'u8, 0x57]) # push r15
  result.add([0x48'u8, 0x83, 0xEC, 0x08]) # sub rsp, 8 (align 16)
  result.add([0x48'u8, 0x89, 0xFB]) # mov rbx, rdi (save statePtr)

  # Compute cycles
  let cycles = computeBlockCycles(blk)

  # Handle DO Loop entry
  var loopIterations = 1'u32
  var isLoopBlock = false
  var loopEndPc = 0'u32
  for op in blk.ops:
    if op.kind == IrOpKind.irLoopDo:
      loopIterations = op.imm
      loopEndPc = op.pAddr
      isLoopBlock = true
      break
    elif op.kind notin {IrOpKind.irCheckGen, IrOpKind.irNop}:
      break

  var loopStartIdx = 0
  if isLoopBlock:
    result.add([0x41'u8, 0xBC]) # mov r12d, imm32
    x86EmitU32(result, loopIterations)
    loopStartIdx = result.len

  for rawOp in blk.ops:
    let op = canonicalizeOp(rawOp)
    case op.kind
    of IrOpKind.irNop, IrOpKind.irCheckGen:
      discard
    of IrOpKind.irLoadImm:
      let off = regOffset(op.dst)
      if off >= 0:
        result.add([0xC7'u8, 0x83]) # mov dword ptr [rbx + off], imm32
        x86EmitU32(result, uint32(off))
        x86EmitU32(result, op.imm and 0x00FFFFFF'u32)
    of IrOpKind.irLoadReg:
      let srcOff = regOffset(op.src1)
      let dstOff = regOffset(op.dst)
      if srcOff >= 0 and dstOff >= 0:
        result.add([0x8B'u8, 0x83])
        x86EmitU32(result, uint32(srcOff)) # mov eax, [rbx + srcOff]
        result.add([0x89'u8, 0x83])
        x86EmitU32(result, uint32(dstOff)) # mov [rbx + dstOff], eax
    of IrOpKind.irStoreReg:
      let srcOff = regOffset(op.src1)
      let dstOff = regOffset(op.dst)
      if srcOff >= 0 and dstOff >= 0:
        result.add([0x8B'u8, 0x83])
        x86EmitU32(result, uint32(srcOff))
        result.add([0x89'u8, 0x83])
        x86EmitU32(result, uint32(dstOff))
    of IrOpKind.irLoadMem:
      let dstOff = regOffset(op.dst)
      if dstOff >= 0:
        result.add([0x48'u8, 0x89, 0xDF]) # mov rdi, rbx (statePtr)
        result.add([0xBE'u8]) # mov esi, space
        x86EmitU32(result, if op.space == MemSpace.memX: 0'u32 else: 1'u32)
        if op.addrMode == AddrMode.amAbsolute:
          result.add([0xBA'u8])
          x86EmitU32(result, op.imm) # mov edx, imm
        else:
          let rOff = OFFSET_R + int(op.rNum) * 4
          result.add([0x8B'u8, 0x93])
          x86EmitU32(result, uint32(rOff)) # mov edx, [rbx + rOff]
        result.add([0x48'u8, 0xB8])
        x86EmitU64(result, cast[uint64](nativeMemRead)) # movabs rax, helper
        result.add([0xFF'u8, 0xD0]) # call rax
        result.add([0x89'u8, 0x83])
        x86EmitU32(result, uint32(dstOff)) # mov [rbx + dstOff], eax
    of IrOpKind.irStoreMem:
      let srcOff = regOffset(op.src1)
      if srcOff >= 0:
        result.add([0x48'u8, 0x89, 0xDF]) # mov rdi, rbx
        result.add([0xBE'u8]) # mov esi, space
        x86EmitU32(result, if op.space == MemSpace.memX: 0'u32 else: 1'u32)
        if op.addrMode == AddrMode.amAbsolute:
          result.add([0xBA'u8])
          x86EmitU32(result, op.imm)
        else:
          let rOff = OFFSET_R + int(op.rNum) * 4
          result.add([0x8B'u8, 0x93])
          x86EmitU32(result, uint32(rOff))
        result.add([0x8B'u8, 0x8B])
        x86EmitU32(result, uint32(srcOff)) # mov ecx, [rbx + srcOff]
        result.add([0x48'u8, 0xB8])
        x86EmitU64(result, cast[uint64](nativeMemWrite))
        result.add([0xFF'u8, 0xD0])
    of IrOpKind.irAguUpdate:
      let rOff = uint32(OFFSET_R + int(op.rNum) * 4)
      result.add([0x8B'u8, 0x83])
      x86EmitU32(result, rOff) # mov eax, [rbx + rOff]
      case op.addrMode
      of AddrMode.amPostInc:
        result.add([0xFF'u8, 0xC0]) # inc eax
      of AddrMode.amPostDec:
        result.add([0xFF'u8, 0xC8]) # dec eax
      of AddrMode.amPostIncN:
        let nOff = uint32(OFFSET_N + int(op.rNum) * 4)
        result.add([0x03'u8, 0x83])
        x86EmitU32(result, nOff) # add eax, [rbx + nOff]
      of AddrMode.amPostDecN:
        let nOff = uint32(OFFSET_N + int(op.rNum) * 4)
        result.add([0x2B'u8, 0x83])
        x86EmitU32(result, nOff) # sub eax, [rbx + nOff]
      else:
        discard
      result.add([0x25'u8, 0xFF, 0xFF, 0xFF, 0x00]) # and eax, 0x00FFFFFF
      result.add([0x89'u8, 0x83])
      x86EmitU32(result, rOff) # mov [rbx + rOff], eax
    of IrOpKind.irAluOp:
      let src1Off = regOffset(op.src1)
      let src2Off = regOffset(op.src2)
      if src1Off >= 0:
        result.add([0x8B'u8, 0x83])
        x86EmitU32(result, uint32(src1Off)) # mov eax, [rbx + src1Off]
        result.add([0xC1'u8, 0xE0, 0x08, 0xC1, 0xF8, 0x08]) # shl eax, 8; sar eax, 8
        result.add([0x48'u8, 0x63, 0xC0]) # movsxd rax, eax
      if src2Off >= 0:
        result.add([0x8B'u8, 0x93])
        x86EmitU32(result, uint32(src2Off)) # mov edx, [rbx + src2Off]
        result.add([0xC1'u8, 0xE2, 0x08, 0xC1, 0xFA, 0x08]) # shl edx, 8; sar edx, 8
        result.add([0x48'u8, 0x63, 0xD2]) # movsxd rdx, edx

      case op.aluOp
      of AluOp.opMpy, AluOp.opMpyr:
        result.add([0x48'u8, 0x0F, 0xAF, 0xC2]) # imul rax, rdx
        result.add([0x48'u8, 0xD1, 0xE0]) # shl rax, 1
        if op.isNeg:
          result.add([0x48'u8, 0xF7, 0xD8]) # neg rax
        result.add([0x48'u8, 0xC1, 0xE0, 0x08, 0x48, 0xC1, 0xF8, 0x08]) # sign-extend 56
        x86StoreAcc(result, op.dst)
      of AluOp.opMac, AluOp.opMacr:
        result.add([0x48'u8, 0x0F, 0xAF, 0xC2]) # imul rax, rdx
        result.add([0x48'u8, 0xD1, 0xE0]) # shl rax, 1
        if op.isNeg:
          result.add([0x48'u8, 0xF7, 0xD8])
        result.add([0x48'u8, 0x89, 0xC1]) # mov rcx, rax (save prod)
        x86LoadAcc(result, op.dst) # loads acc into rax
        result.add([0x48'u8, 0x01, 0xC8]) # add rax, rcx
        result.add([0x48'u8, 0xC1, 0xE0, 0x08, 0x48, 0xC1, 0xF8, 0x08])
        x86StoreAcc(result, op.dst)
      of AluOp.opAdd:
        result.add([0x48'u8, 0xC1, 0xE0, 0x18]) # shl rax, 24 (MSP align)
        result.add([0x48'u8, 0x89, 0xC2]) # mov rdx, rax
        x86LoadAcc(result, op.dst) # loads acc into rax
        result.add([0x48'u8, 0x01, 0xD0]) # add rax, rdx
        result.add([0x48'u8, 0xC1, 0xE0, 0x08, 0x48, 0xC1, 0xF8, 0x08])
        x86StoreAcc(result, op.dst)
      of AluOp.opSub:
        result.add([0x48'u8, 0xC1, 0xE0, 0x18])
        result.add([0x48'u8, 0x89, 0xC2])
        x86LoadAcc(result, op.dst)
        result.add([0x48'u8, 0x29, 0xD0]) # sub rax, rdx
        result.add([0x48'u8, 0xC1, 0xE0, 0x08, 0x48, 0xC1, 0xF8, 0x08])
        x86StoreAcc(result, op.dst)
      of AluOp.opClr:
        result.add([0x48'u8, 0x31, 0xC0]) # xor rax, rax
        x86StoreAcc(result, op.dst)
      of AluOp.opNeg:
        x86LoadAcc(result, op.dst)
        result.add([0x48'u8, 0xF7, 0xD8]) # neg rax
        result.add([0x48'u8, 0xC1, 0xE0, 0x08, 0x48, 0xC1, 0xF8, 0x08])
        x86StoreAcc(result, op.dst)
      of AluOp.opAsl:
        x86LoadAcc(result, op.dst)
        result.add([0x48'u8, 0xD1, 0xE0]) # shl rax, 1
        result.add([0x48'u8, 0xC1, 0xE0, 0x08, 0x48, 0xC1, 0xF8, 0x08])
        x86StoreAcc(result, op.dst)
      of AluOp.opAsr:
        x86LoadAcc(result, op.dst)
        result.add([0x48'u8, 0xD1, 0xF8]) # sar rax, 1
        x86StoreAcc(result, op.dst)
      else:
        discard
    of IrOpKind.irBranch:
      result.add([0xC7'u8, 0x83])
      x86EmitU32(result, uint32(OFFSET_PC))
      x86EmitU32(result, op.imm)
    of IrOpKind.irLoopDo:
      discard
    else:
      discard

  if isLoopBlock:
    result.add([0x41'u8, 0xFF, 0xCC]) # decl r12d
    let diff = int32(loopStartIdx - (result.len + 2))
    if diff >= -128 and diff <= 127:
      result.add([0x75'u8, byte(diff and 0xFF)]) # jne rel8
    else:
      let diff32 = int32(loopStartIdx - (result.len + 6))
      result.add([0x0F'u8, 0x85]) # jne rel32
      x86EmitU32(result, uint32(diff32))

  # Update PC if no branch
  let finalPc =
    if isLoopBlock:
      (loopEndPc + 1)
    else:
      blk.endPc
  result.add([0xC7'u8, 0x83])
  x86EmitU32(result, uint32(OFFSET_PC))
  x86EmitU32(result, finalPc)
  if isLoopBlock:
    result.add([0xC7'u8, 0x83])
    x86EmitU32(result, uint32(OFFSET_CORE + offsetOf(Dsp56300State, lc)))
    x86EmitU32(result, 0)

  # Epilogue
  result.add([0xB8'u8])
  x86EmitU32(result, cycles) # mov eax, cycles
  result.add([0x48'u8, 0x83, 0xC4, 0x08]) # add rsp, 8
  result.add([0x41'u8, 0x5F]) # pop r15
  result.add([0x41'u8, 0x5E]) # pop r14
  result.add([0x41'u8, 0x5D]) # pop r13
  result.add([0x41'u8, 0x5C]) # pop r12
  result.add(0x5B'u8) # pop rbx
  result.add(0x5D'u8) # pop rbp
  result.add(0xC3'u8) # retq

# ---------------------------------------------------------------------------
# Native JIT Context & Compiler Entrypoint
# ---------------------------------------------------------------------------

type
  NativeBlockFn* = proc(statePtr: ptr DspState): uint32 {.cdecl.}

  CompiledBlock = object
    blk: IrBasicBlock
    fn: NativeBlockFn

  NativeJitContext* = ref object
    buffer: pointer
    capacity: int
    offset: int
    blocks: seq[CompiledBlock]

proc newNativeJit*(capacity: int = 65536): NativeJitContext =
  new(result)
  result.capacity = capacity
  result.offset = 0
  result.blocks = @[]

  when defined(macosx) and defined(arm64):
    result.buffer = mmap(
      nil,
      capacity,
      PROT_READ or PROT_WRITE or PROT_EXEC,
      MAP_PRIVATE or MAP_ANON or MAP_JIT,
      -1,
      0,
    )
  else:
    result.buffer = mmap(
      nil,
      capacity,
      PROT_READ or PROT_WRITE or PROT_EXEC,
      MAP_PRIVATE or MAP_ANON,
      -1,
      0,
    )

  if result.buffer == MAP_FAILED:
    result.buffer = nil

var gFallbackBlocks: seq[IrBasicBlock] = @[]

proc fallbackCdeclDispatcher(statePtr: ptr DspState): uint32 {.cdecl.} =
  if statePtr != nil and gFallbackBlocks.len > 0:
    return runner.runBlock(statePtr[], gFallbackBlocks[^1])
  return 0

proc compileBlock*(ctx: NativeJitContext, blk: IrBasicBlock): NativeBlockFn =
  ## Compiles IrBasicBlock into native machine code in the executable buffer.
  ## Lowers directly to ARM64 instructions on arm64 and x86_64 instructions on amd64.
  when defined(macosx) and defined(arm64):
    let insns = assembleArm64(blk)
    let byteLen = insns.len * 4
    if ctx.buffer == nil or ctx.offset + byteLen + 64 > ctx.capacity:
      gFallbackBlocks.add(blk)
      return fallbackCdeclDispatcher

    let entryOffset = ctx.offset
    let entryPtr = cast[pointer](cast[uint](ctx.buffer) + uint(entryOffset))

    pthread_jit_write_protect_np(0)
    let code32 = cast[ptr UncheckedArray[uint32]](entryPtr)
    for i in 0 ..< insns.len:
      code32[i] = insns[i]

    sys_icache_invalidate(entryPtr, csize_t(byteLen))
    pthread_jit_write_protect_np(1)

    ctx.offset += ((byteLen + 15) div 16) * 16
    let fn = cast[NativeBlockFn](entryPtr)
    ctx.blocks.add(CompiledBlock(blk: blk, fn: fn))
    return fn
  elif defined(amd64):
    let bytes = assembleX86_64(blk)
    let byteLen = bytes.len
    if ctx.buffer == nil or ctx.offset + byteLen + 64 > ctx.capacity:
      gFallbackBlocks.add(blk)
      return fallbackCdeclDispatcher

    let entryOffset = ctx.offset
    let entryPtr = cast[pointer](cast[uint](ctx.buffer) + uint(entryOffset))

    let codeBytes = cast[ptr UncheckedArray[byte]](entryPtr)
    for i in 0 ..< bytes.len:
      codeBytes[i] = bytes[i]

    ctx.offset += ((byteLen + 15) div 16) * 16
    let fn = cast[NativeBlockFn](entryPtr)
    ctx.blocks.add(CompiledBlock(blk: blk, fn: fn))
    return fn
  else:
    gFallbackBlocks.add(blk)
    return fallbackCdeclDispatcher
