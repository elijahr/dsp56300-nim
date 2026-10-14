# Clean-room MIT implementation of Motorola DSP56300 / DSP56311 Core
# Canonical C11 ABI Export Layer

import dsp56300/state
import dsp56300/memory
import dsp56300/alu
import dsp56300/agu
import dsp56300/loops

export state, memory, alu, agu, loops

type
  Dsp56300Ctx* = object
    state*: Dsp56300State
    mem*: Dsp56300Memory

  Dsp56300Config* {.bycopy.} = object
    user*: pointer
    rd*: Dsp56300MemReadFn
    wr*: Dsp56300MemWriteFn
    omrInit*: uint32

# Exported C11 ABI Functions

proc dsp56300_runtime_init*(): cint {.exportc: "dsp56300_runtime_init", cdecl, dynlib.} =
  return 0

proc dsp56300_create*(config: ptr Dsp56300Config): ptr Dsp56300Ctx {.exportc: "dsp56300_create", cdecl, dynlib.} =
  let ctx = create(Dsp56300Ctx)
  ctx.mem = initMemory()
  let omrInit = if config != nil: config.omrInit else: 0'u32
  ctx.state.reset(omrInit)

  if config != nil:
    ctx.mem.userContext = config.user
    ctx.mem.extReadFn = config.rd
    ctx.mem.extWriteFn = config.wr

  return ctx

proc dsp56300_destroy*(ctx: ptr Dsp56300Ctx) {.exportc: "dsp56300_destroy", cdecl, dynlib.} =
  if ctx != nil:
    dealloc(ctx)

proc dsp56300_reset*(ctx: ptr Dsp56300Ctx) {.exportc: "dsp56300_reset", cdecl, dynlib.} =
  if ctx != nil:
    let omr = ctx.state.omr
    ctx.state.reset(omr)

proc dsp56300_exec*(ctx: ptr Dsp56300Ctx, maxCycles: uint32): uint32 {.exportc: "dsp56300_exec", cdecl, dynlib.} =
  if ctx == nil or ctx.state.halted:
    return 0
  # Basic cycle execution counter
  ctx.state.cycleCount += uint64(maxCycles)
  return maxCycles

proc dsp56300_set_reg*(ctx: ptr Dsp56300Ctx, regIndex: cint, value: uint64): cint {.exportc: "dsp56300_set_reg", cdecl, dynlib.} =
  if ctx == nil:
    return -1

  case regIndex
  of 0: ctx.state.x0 = mask24(uint32(value))
  of 1: ctx.state.x1 = mask24(uint32(value))
  of 2: ctx.state.y0 = mask24(uint32(value))
  of 3: ctx.state.y1 = mask24(uint32(value))
  of 4: ctx.state.setX(value)
  of 5: ctx.state.setY(value)

  of 6: ctx.state.a0 = mask24(uint32(value))
  of 7: ctx.state.a1 = mask24(uint32(value))
  of 8: ctx.state.a2 = uint8(value and 0xFF'u64)
  of 9: ctx.state.setA10(value)
  of 10: ctx.state.setA(cast[int64](value))

  of 11: ctx.state.b0 = mask24(uint32(value))
  of 12: ctx.state.b1 = mask24(uint32(value))
  of 13: ctx.state.b2 = uint8(value and 0xFF'u64)
  of 14: ctx.state.setB10(value)
  of 15: ctx.state.setB(cast[int64](value))

  of 16..23: ctx.state.r[regIndex - 16] = mask24(uint32(value))
  of 24..31: ctx.state.n[regIndex - 24] = mask24(uint32(value))
  of 32..39: ctx.state.m[regIndex - 32] = mask24(uint32(value))

  of 40: ctx.state.pc = mask24(uint32(value))
  of 41: ctx.state.sr = mask24(uint32(value))
  of 42: ctx.state.omr = mask24(uint32(value))
  of 43: ctx.state.la = mask24(uint32(value))
  of 44: ctx.state.lc = mask24(uint32(value))
  of 45: ctx.state.sp = mask24(uint32(value))
  of 46:
    let idx = (int(ctx.state.sp and SP_CTR_MASK) - 1) and 0x0F
    ctx.state.ssh[idx] = mask24(uint32(value))
  of 47:
    let idx = (int(ctx.state.sp and SP_CTR_MASK) - 1) and 0x0F
    ctx.state.ssl[idx] = mask24(uint32(value))
  of 48: ctx.state.vba = mask24(uint32(value))
  of 49: ctx.state.ep = mask24(uint32(value))
  of 50: ctx.state.sz = mask24(uint32(value))
  of 51: ctx.state.sc = mask24(uint32(value))
  else:
    return -1

  return 0

proc dsp56300_get_reg*(ctx: ptr Dsp56300Ctx, regIndex: cint, value: ptr uint64): cint {.exportc: "dsp56300_get_reg", cdecl, dynlib.} =
  if ctx == nil or value == nil:
    return -1

  case regIndex
  of 0: value[] = uint64(ctx.state.x0)
  of 1: value[] = uint64(ctx.state.x1)
  of 2: value[] = uint64(ctx.state.y0)
  of 3: value[] = uint64(ctx.state.y1)
  of 4: value[] = ctx.state.getX()
  of 5: value[] = ctx.state.getY()

  of 6: value[] = uint64(ctx.state.a0)
  of 7: value[] = uint64(ctx.state.a1)
  of 8: value[] = uint64(ctx.state.a2)
  of 9: value[] = ctx.state.getA10()
  of 10: value[] = cast[uint64](ctx.state.getA())

  of 11: value[] = uint64(ctx.state.b0)
  of 12: value[] = uint64(ctx.state.b1)
  of 13: value[] = uint64(ctx.state.b2)
  of 14: value[] = ctx.state.getB10()
  of 15: value[] = cast[uint64](ctx.state.getB())

  of 16..23: value[] = uint64(ctx.state.r[regIndex - 16])
  of 24..31: value[] = uint64(ctx.state.n[regIndex - 24])
  of 32..39: value[] = uint64(ctx.state.m[regIndex - 32])

  of 40: value[] = uint64(ctx.state.pc)
  of 41: value[] = uint64(ctx.state.sr)
  of 42: value[] = uint64(ctx.state.omr)
  of 43: value[] = uint64(ctx.state.la)
  of 44: value[] = uint64(ctx.state.lc)
  of 45: value[] = uint64(ctx.state.sp)
  of 46:
    let idx = (int(ctx.state.sp and SP_CTR_MASK) - 1) and 0x0F
    value[] = uint64(ctx.state.ssh[idx])
  of 47:
    let idx = (int(ctx.state.sp and SP_CTR_MASK) - 1) and 0x0F
    value[] = uint64(ctx.state.ssl[idx])
  of 48: value[] = uint64(ctx.state.vba)
  of 49: value[] = uint64(ctx.state.ep)
  of 50: value[] = uint64(ctx.state.sz)
  of 51: value[] = uint64(ctx.state.sc)
  else:
    return -1

  return 0

proc dsp56300_mem_read*(ctx: ptr Dsp56300Ctx, space: cint, address: uint32): uint32 {.exportc: "dsp56300_mem_read", cdecl, dynlib.} =
  if ctx == nil or space < 0 or space > 2:
    return 0
  return ctx.mem.readMem(ctx.state, Dsp56300Space(space), address)

proc dsp56300_mem_write*(ctx: ptr Dsp56300Ctx, space: cint, address: uint32, val: uint32) {.exportc: "dsp56300_mem_write", cdecl, dynlib.} =
  if ctx != nil and space >= 0 and space <= 2:
    ctx.mem.writeMem(ctx.state, Dsp56300Space(space), address, val)

proc dsp56300_register_peripheral*(ctx: ptr Dsp56300Ctx, space: cint, baseAddr: uint32,
                                  size: uint32, rd: Dsp56300MemReadFn,
                                  wr: Dsp56300MemWriteFn, user: pointer): cint {.exportc: "dsp56300_register_peripheral", cdecl, dynlib.} =
  if ctx == nil or space < 0 or space > 2:
    return -1
  ctx.mem.registerHook(Dsp56300Space(space), baseAddr, size, rd, wr, user)
  return 0

proc dsp56300_halted*(ctx: ptr Dsp56300Ctx): cint {.exportc: "dsp56300_halted", cdecl, dynlib.} =
  if ctx == nil or ctx.state.halted:
    return 1
  return 0

proc dsp56300_state_size*(): csize_t {.exportc: "dsp56300_state_size", cdecl, dynlib.} =
  return csize_t(sizeof(Dsp56300State))

proc dsp56300_state_save*(ctx: ptr Dsp56300Ctx, dst: pointer) {.exportc: "dsp56300_state_save", cdecl, dynlib.} =
  if ctx != nil and dst != nil:
    copyMem(dst, addr(ctx.state), sizeof(Dsp56300State))

proc dsp56300_state_load*(ctx: ptr Dsp56300Ctx, src: pointer) {.exportc: "dsp56300_state_load", cdecl, dynlib.} =
  if ctx != nil and src != nil:
    copyMem(addr(ctx.state), src, sizeof(Dsp56300State))

import dsp56300/peripherals/peripherals56311
export peripherals56311


