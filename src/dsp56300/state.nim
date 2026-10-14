# Clean-room MIT implementation of Motorola DSP56300 / DSP56311 CPU State
# Hardware Reference: DSP56300FM Chapter 3, 4, 5; DSP56311UM Chapter 1, 3, 4

type
  Dsp56300State* = object
    # Data ALU Input Registers (24-bit)
    x0*: uint32
    x1*: uint32
    y0*: uint32
    y1*: uint32

    # Data ALU Accumulator Registers (A = A2:A1:A0, B = B2:B1:B0)
    # A2/B2: 8-bit extension (stored in uint8)
    # A1/B1: 24-bit most significant portion (MSP)
    # A0/B0: 24-bit least significant portion (LSP)
    a2*: uint8
    a1*: uint32
    a0*: uint32

    b2*: uint8
    b1*: uint32
    b0*: uint32

    # Address Generation Unit (AGU) Registers (24-bit)
    r*: array[8, uint32]  # R0..R7 Address registers
    n*: array[8, uint32]  # N0..N7 Offset registers
    m*: array[8, uint32]  # M0..M7 Modifier registers

    # Program Control Unit (PCU) Registers (24-bit)
    pc*: uint32           # Program Counter
    sr*: uint32           # Status Register (EMR:MR:CCR)
    omr*: uint32          # Operating Mode Register
    la*: uint32           # Loop Address Register
    lc*: uint32           # Loop Counter Register
    sp*: uint32           # Stack Pointer Register (4-bit counter + flags)
    vba*: uint32          # Vector Base Address Register
    ep*: uint32           # Stack Extension Pointer Register
    sz*: uint32           # Stack Size Register
    sc*: uint32           # Stack Counter Register

    # Hardware System Stack (16 levels x 48 bits, accessed as SSH:SSL)
    ssh*: array[16, uint32]
    ssl*: array[16, uint32]

    # Repeat Instruction state (for REP)
    repActive*: bool
    repCount*: uint32

    # Core execution control flags
    halted*: bool
    waiting*: bool
    stopped*: bool
    cycleCount*: uint64

# Bit Masks for Status Register (SR)
# SR is 24-bit: EMR (bits 23-16), MR (bits 15-8), CCR (bits 7-0)
const
  # Condition Code Register (CCR, SR[7..0])
  SR_C*  = 1'u32 shl 0   # Carry / Borrow
  SR_V*  = 1'u32 shl 1   # Overflow
  SR_Z*  = 1'u32 shl 2   # Zero
  SR_N*  = 1'u32 shl 3   # Negative
  SR_U*  = 1'u32 shl 4   # Unnormalized
  SR_E*  = 1'u32 shl 5   # Extension in use
  SR_L*  = 1'u32 shl 6   # Limit (sticky)
  SR_S*  = 1'u32 shl 7   # Scaling (sticky)

  # Mode Register (MR, SR[15..8])
  SR_I0* = 1'u32 shl 8   # Interrupt Mask bit 0
  SR_I1* = 1'u32 shl 9   # Interrupt Mask bit 1
  SR_S0* = 1'u32 shl 10  # Scaling Mode bit 0
  SR_S1* = 1'u32 shl 11  # Scaling Mode bit 1
  SR_SC* = 1'u32 shl 13  # Sixteen-Bit Compatibility Mode
  SR_DM* = 1'u32 shl 14  # Double-Precision Multiply Mode
  SR_LF* = 1'u32 shl 15  # DO Loop Flag

  # Extended Mode Register (EMR, SR[23..16])
  SR_FV* = 1'u32 shl 16  # DO FOREVER Flag
  SR_SA* = 1'u32 shl 17  # Sixteen-Bit Arithmetic Mode
  SR_CE* = 1'u32 shl 19  # Cache Enable
  SR_SM* = 1'u32 shl 20  # Arithmetic Saturation Mode
  SR_RM* = 1'u32 shl 21  # Rounding Mode (0: convergent, 1: two's complement)
  SR_CP0* = 1'u32 shl 22  # Core Priority bit 0
  SR_CP1* = 1'u32 shl 23  # Core Priority bit 1

  # Reset value of SR: CP1=1, CP0=1, I1=1, I0=1 (0xC00300)
  SR_RESET_VALUE* = SR_CP1 or SR_CP0 or SR_I1 or SR_I0

# Operating Mode Register (OMR) Bit Masks
const
  OMR_MA*  = 1'u32 shl 0  # Chip Operating Mode bit A
  OMR_MB*  = 1'u32 shl 1  # Chip Operating Mode bit B
  OMR_MC*  = 1'u32 shl 2  # Chip Operating Mode bit C
  OMR_MD*  = 1'u32 shl 3  # Chip Operating Mode bit D
  OMR_EBD* = 1'u32 shl 4  # External Bus Disable
  OMR_SD*  = 1'u32 shl 6  # Stop Delay
  OMR_MS*  = 1'u32 shl 7  # Memory Switch Mode
  OMR_BE*  = 1'u32 shl 10 # Burst Enable
  OMR_SEN* = 1'u32 shl 11 # Stack Extension Enable
  OMR_XYS* = 1'u32 shl 14 # Stack Space (0: X, 1: Y)
  OMR_MSW0* = 1'u32 shl 16 # Memory Switch Window bit 0
  OMR_MSW1* = 1'u32 shl 17 # Memory Switch Window bit 1

# Stack Pointer (SP) Register Bit Masks
const
  SP_CTR_MASK* = 0x00000F'u32 # 4-bit stack level counter (0..15)
  SP_UF*       = 1'u32 shl 4  # Stack Underflow flag
  SP_OF*       = 1'u32 shl 5  # Stack Overflow flag
  SP_SE*       = 1'u32 shl 6  # Stack Error flag

# 24-Bit Mask & Signed Extension Helpers
template mask24*(v: uint32): uint32 =
  v and 0x00FFFFFF'u32

template signExtend24*(v: uint32): int32 =
  let m = v and 0x00FFFFFF'u32
  if (m and 0x00800000'u32) != 0:
    cast[int32](m or 0xFF000000'u32)
  else:
    cast[int32](m)

template signExtend8To24*(v: uint8): uint32 =
  if (v and 0x80'u8) != 0:
    0x00FFFF00'u32 or uint32(v)
  else:
    uint32(v)

# 56-Bit Accumulator Converters
# Accumulator representation: 56 bits stored in int64.
# Bit 55 is sign bit, bits 55..48 is EXT (A2/B2), bits 47..24 is MSP (A1/B1), bits 23..0 is LSP (A0/B0).
proc toAccum56*(a2: uint8, a1: uint32, a0: uint32): int64 {.inline.} =
  let raw = (uint64(a2) shl 48) or
            ((uint64(a1) and 0x00FFFFFF'u64) shl 24) or
            (uint64(a0) and 0x00FFFFFF'u64)
  # Sign-extend bit 55 to bit 63
  if (raw and (1'u64 shl 55)) != 0:
    cast[int64](raw or 0xFF00000000000000'u64)
  else:
    cast[int64](raw)

proc fromAccum56*(val: int64, a2: var uint8, a1: var uint32, a0: var uint32) {.inline.} =
  let u = cast[uint64](val)
  a2 = uint8((u shr 48) and 0xFF'u64)
  a1 = uint32((u shr 24) and 0x00FFFFFF'u64)
  a0 = uint32(u and 0x00FFFFFF'u64)

proc getA*(s: Dsp56300State): int64 {.inline.} =
  toAccum56(s.a2, s.a1, s.a0)

proc setA*(s: var Dsp56300State, val: int64) {.inline.} =
  fromAccum56(val, s.a2, s.a1, s.a0)

proc getB*(s: Dsp56300State): int64 {.inline.} =
  toAccum56(s.b2, s.b1, s.b0)

proc setB*(s: var Dsp56300State, val: int64) {.inline.} =
  fromAccum56(val, s.b2, s.b1, s.b0)

proc getX*(s: Dsp56300State): uint64 {.inline.} =
  ((uint64(s.x1) and 0x00FFFFFF'u64) shl 24) or (uint64(s.x0) and 0x00FFFFFF'u64)

proc setX*(s: var Dsp56300State, val: uint64) {.inline.} =
  s.x1 = uint32((val shr 24) and 0x00FFFFFF'u64)
  s.x0 = uint32(val and 0x00FFFFFF'u64)

proc getY*(s: Dsp56300State): uint64 {.inline.} =
  ((uint64(s.y1) and 0x00FFFFFF'u64) shl 24) or (uint64(s.y0) and 0x00FFFFFF'u64)

proc setY*(s: var Dsp56300State, val: uint64) {.inline.} =
  s.y1 = uint32((val shr 24) and 0x00FFFFFF'u64)
  s.y0 = uint32(val and 0x00FFFFFF'u64)

proc getA10*(s: Dsp56300State): uint64 {.inline.} =
  ((uint64(s.a1) and 0x00FFFFFF'u64) shl 24) or (uint64(s.a0) and 0x00FFFFFF'u64)

proc setA10*(s: var Dsp56300State, val: uint64) {.inline.} =
  s.a1 = uint32((val shr 24) and 0x00FFFFFF'u64)
  s.a0 = uint32(val and 0x00FFFFFF'u64)
  # Sign extension into A2 when written as long word
  if (s.a1 and 0x00800000'u32) != 0:
    s.a2 = 0xFF'u8
  else:
    s.a2 = 0x00'u8

proc getB10*(s: Dsp56300State): uint64 {.inline.} =
  ((uint64(s.b1) and 0x00FFFFFF'u64) shl 24) or (uint64(s.b0) and 0x00FFFFFF'u64)

proc setB10*(s: var Dsp56300State, val: uint64) {.inline.} =
  s.b1 = uint32((val shr 24) and 0x00FFFFFF'u64)
  s.b0 = uint32(val and 0x00FFFFFF'u64)
  # Sign extension into B2 when written as long word
  if (s.b1 and 0x00800000'u32) != 0:
    s.b2 = 0xFF'u8
  else:
    s.b2 = 0x00'u8

# Stack Operations
proc stackPush*(s: var Dsp56300State, sshVal, sslVal: uint32) =
  let ptrIdx = int(s.sp and SP_CTR_MASK)
  s.ssh[ptrIdx] = mask24(sshVal)
  s.ssl[ptrIdx] = mask24(sslVal)
  let nextPtr = (ptrIdx + 1) and 0x0F
  s.sp = (s.sp and not SP_CTR_MASK) or uint32(nextPtr)
  if nextPtr == 0:
    # Overflow occurred (wrapped around 16 entries)
    s.sp = s.sp or SP_OF

proc stackPop*(s: var Dsp56300State, sshVal, sslVal: var uint32) =
  let ptrIdx = int(s.sp and SP_CTR_MASK)
  let prevPtr = (ptrIdx - 1) and 0x0F
  s.sp = (s.sp and not SP_CTR_MASK) or uint32(prevPtr)
  sshVal = s.ssh[prevPtr]
  sslVal = s.ssl[prevPtr]
  if ptrIdx == 0:
    # Underflow occurred
    s.sp = s.sp or SP_UF

proc stackPeek*(s: Dsp56300State, sshVal, sslVal: var uint32) =
  let ptrIdx = int(s.sp and SP_CTR_MASK)
  let topPtr = (ptrIdx - 1) and 0x0F
  sshVal = s.ssh[topPtr]
  sslVal = s.ssl[topPtr]

# Core Reset
proc reset*(s: var Dsp56300State, omrVal: uint32 = 0) =
  s.x0 = 0
  s.x1 = 0
  s.y0 = 0
  s.y1 = 0
  s.a2 = 0
  s.a1 = 0
  s.a0 = 0
  s.b2 = 0
  s.b1 = 0
  s.b0 = 0

  for i in 0..7:
    s.r[i] = 0
    s.n[i] = 0
    s.m[i] = 0x00FFFFFF'u32 # Linear addressing default on reset

  s.pc = 0
  s.sr = SR_RESET_VALUE
  s.omr = mask24(omrVal)
  s.la = 0
  s.lc = 0
  s.sp = 0
  s.vba = 0
  s.ep = 0
  s.sz = 0
  s.sc = 0

  for i in 0..15:
    s.ssh[i] = 0
    s.ssl[i] = 0

  s.repActive = false
  s.repCount = 0
  s.halted = false
  s.waiting = false
  s.stopped = false
  s.cycleCount = 0
