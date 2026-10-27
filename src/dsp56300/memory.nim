# Clean-room MIT implementation of Motorola DSP56300 / DSP56311 Memory Subsystem
# Hardware Reference: DSP56300FM Chapter 9, DSP56311UM Chapter 3, Appendix B

import state

type
  Dsp56300Space* {.size: sizeof(cint).} = enum
    SpaceX = 0
    SpaceY = 1
    SpaceP = 2

  Dsp56300MemReadFn* =
    proc(user: pointer, space: cint, address: uint32): uint32 {.cdecl.}
  Dsp56300MemWriteFn* =
    proc(user: pointer, space: cint, address: uint32, val: uint32) {.cdecl.}

  # Peripheral Hook Entry for I/O window ($FFFF80..$FFFFFF)
  PeripheralHook* = object
    baseAddr*: uint32
    size*: uint32
    space*: Dsp56300Space
    readFn*: Dsp56300MemReadFn
    writeFn*: Dsp56300MemWriteFn
    userData*: pointer

  Dsp56300Memory* = object
    # Internal Physical RAM Blocks (allocated to cover maximum internal allocation)
    # P-RAM: up to 96K words (98,304 words)
    pRam*: seq[uint32]
    # X-RAM: up to 48K words (49,152 words)
    xRam*: seq[uint32]
    # Y-RAM: up to 48K words (49,152 words)
    yRam*: seq[uint32]
    # Bootstrap ROM: 192 words ($FF0000..$FF00BF)
    bootRom*: array[192, uint32]

    # External bus callback hooks
    userContext*: pointer
    extReadFn*: Dsp56300MemReadFn
    extWriteFn*: Dsp56300MemWriteFn

    # Peripheral hook table
    hooks*: seq[PeripheralHook]

const
  P_RAM_MAX_WORDS* = 98304 # 96K
  X_RAM_MAX_WORDS* = 49152 # 48K
  Y_RAM_MAX_WORDS* = 49152 # 48K

  BOOT_ROM_BASE* = 0xFF0000'u32
  BOOT_ROM_SIZE* = 192'u32

  IO_WINDOW_BASE* = 0xFFFF80'u32
  IO_WINDOW_TOP* = 0xFFFFFF'u32

proc initMemory*(): Dsp56300Memory =
  result.pRam = newSeq[uint32](P_RAM_MAX_WORDS)
  result.xRam = newSeq[uint32](X_RAM_MAX_WORDS)
  result.yRam = newSeq[uint32](Y_RAM_MAX_WORDS)
  result.hooks = @[]

proc registerHook*(
    mem: var Dsp56300Memory,
    space: Dsp56300Space,
    baseAddr: uint32,
    size: uint32,
    readFn: Dsp56300MemReadFn,
    writeFn: Dsp56300MemWriteFn,
    userData: pointer,
) =
  mem.hooks.add(
    PeripheralHook(
      baseAddr: baseAddr,
      size: size,
      space: space,
      readFn: readFn,
      writeFn: writeFn,
      userData: userData,
    )
  )

proc getRamLimits*(state: Dsp56300State, pLimit, xLimit, yLimit: var uint32) =
  let ms = (state.omr and OMR_MS) != 0
  let msw = (state.omr shr 16) and 0x03'u32

  if not ms:
    # Default mode: P = 32K ($0000..$7FFF), X = 48K ($0000..$BFFF), Y = 48K ($0000..$BFFF)
    pLimit = 32768
    xLimit = 49152
    yLimit = 49152
  else:
    case msw
    of 0: # MSW = 00: P = 96K, X = 16K, Y = 16K
      pLimit = 98304
      xLimit = 16384
      yLimit = 16384
    of 1: # MSW = 01: P = 80K, X = 24K, Y = 24K
      pLimit = 81920
      xLimit = 24576
      yLimit = 24576
    of 2: # MSW = 10: P = 64K, X = 32K, Y = 32K
      pLimit = 65536
      xLimit = 32768
      yLimit = 32768
    of 3: # MSW = 11: P = 48K, X = 40K, Y = 40K
      pLimit = 49152
      xLimit = 40960
      yLimit = 40960
    else:
      pLimit = 32768
      xLimit = 49152
      yLimit = 49152

proc readMem*(
    mem: var Dsp56300Memory, state: Dsp56300State, space: Dsp56300Space, address: uint32
): uint32 {.inline.} =
  let maskedAddr = address and 0x00FFFFFF'u32

  # Internal Physical RAM Fast-Path (< $FFFF80)
  if likely(maskedAddr < IO_WINDOW_BASE):
    case space
    of SpaceX:
      if likely(maskedAddr < uint32(mem.xRam.len)):
        return mem.xRam[maskedAddr]
    of SpaceY:
      if likely(maskedAddr < uint32(mem.yRam.len)):
        return mem.yRam[maskedAddr]
    of SpaceP:
      if likely(maskedAddr < uint32(mem.pRam.len)):
        return mem.pRam[maskedAddr]

  # Check peripheral hooks ($FFFF80..$FFFFFF)
  let numHooks = mem.hooks.len
  if numHooks > 0:
    let hooksPtr = cast[ptr UncheckedArray[PeripheralHook]](addr mem.hooks[0])
    for i in 0 ..< numHooks:
      template hook(): untyped =
        hooksPtr[i]

      if hook.space == space and maskedAddr >= hook.baseAddr and
          maskedAddr < (hook.baseAddr + hook.size):
        if hook.readFn != nil:
          return mask24(hook.readFn(hook.userData, cint(space), maskedAddr))

  var pLimit, xLimit, yLimit: uint32
  getRamLimits(state, pLimit, xLimit, yLimit)

  case space
  of SpaceP:
    # Internal P-RAM
    if maskedAddr < pLimit:
      return mem.pRam[maskedAddr]
    # Bootstrap ROM
    if maskedAddr >= BOOT_ROM_BASE and maskedAddr < (BOOT_ROM_BASE + BOOT_ROM_SIZE):
      let offset = maskedAddr - BOOT_ROM_BASE
      return mem.bootRom[offset]
    # External P Memory
    if mem.extReadFn != nil:
      return mask24(mem.extReadFn(mem.userContext, cint(space), maskedAddr))
    return 0
  of SpaceX:
    # Internal X-RAM
    if maskedAddr < xLimit:
      return mem.xRam[maskedAddr]
    # External X Memory
    if mem.extReadFn != nil:
      return mask24(mem.extReadFn(mem.userContext, cint(space), maskedAddr))
    return 0
  of SpaceY:
    # Internal Y-RAM
    if maskedAddr < yLimit:
      return mem.yRam[maskedAddr]
    # External Y Memory
    if mem.extReadFn != nil:
      return mask24(mem.extReadFn(mem.userContext, cint(space), maskedAddr))
    return 0

proc writeMem*(
    mem: var Dsp56300Memory,
    state: Dsp56300State,
    space: Dsp56300Space,
    address: uint32,
    val: uint32,
) {.inline.} =
  let maskedAddr = address and 0x00FFFFFF'u32
  let maskedVal = val and 0x00FFFFFF'u32

  # Internal Physical RAM Fast-Path (< $FFFF80)
  if likely(maskedAddr < IO_WINDOW_BASE):
    case space
    of SpaceX:
      if likely(maskedAddr < uint32(mem.xRam.len)):
        mem.xRam[maskedAddr] = maskedVal
        return
    of SpaceY:
      if likely(maskedAddr < uint32(mem.yRam.len)):
        mem.yRam[maskedAddr] = maskedVal
        return
    of SpaceP:
      if likely(maskedAddr < uint32(mem.pRam.len)):
        mem.pRam[maskedAddr] = maskedVal
        return

  # Check peripheral hooks ($FFFF80..$FFFFFF)
  let numHooks = mem.hooks.len
  if numHooks > 0:
    let hooksPtr = cast[ptr UncheckedArray[PeripheralHook]](addr mem.hooks[0])
    for i in 0 ..< numHooks:
      template hook(): untyped =
        hooksPtr[i]

      if hook.space == space and maskedAddr >= hook.baseAddr and
          maskedAddr < (hook.baseAddr + hook.size):
        if hook.writeFn != nil:
          hook.writeFn(hook.userData, cint(space), maskedAddr, maskedVal)
          return

  var pLimit, xLimit, yLimit: uint32
  getRamLimits(state, pLimit, xLimit, yLimit)

  case space
  of SpaceP:
    if maskedAddr < pLimit:
      mem.pRam[maskedAddr] = maskedVal
    elif mem.extWriteFn != nil:
      mem.extWriteFn(mem.userContext, cint(space), maskedAddr, maskedVal)
  of SpaceX:
    if maskedAddr < xLimit:
      mem.xRam[maskedAddr] = maskedVal
    elif mem.extWriteFn != nil:
      mem.extWriteFn(mem.userContext, cint(space), maskedAddr, maskedVal)
  of SpaceY:
    if maskedAddr < yLimit:
      mem.yRam[maskedAddr] = maskedVal
    elif mem.extWriteFn != nil:
      mem.extWriteFn(mem.userContext, cint(space), maskedAddr, maskedVal)
