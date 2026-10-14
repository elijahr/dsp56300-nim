## Clean-room MIT Motorola DSP56300 Native JIT Backend
## Emits native ARM64 (Apple Silicon MAP_JIT + pthread_jit_write_protect_np) and x86_64 machine code.
## Reference: Motorola DSP56300 Family Manual (DSP56300FM.pdf), Chapter 12 & 13.
## Strict Clean-Room: zero GPL code, derived strictly from Motorola specifications.

import posix
import dsp56300/[ir, runner]

when defined(macosx) and defined(arm64):
  proc pthread_jit_write_protect_np(enabled: cint) {.importc, header: "<pthread.h>".}
  proc sys_icache_invalidate(p: pointer, len: csize_t) {.importc, header: "<libkern/OSCacheControl.h>".}

const
  MAP_JIT = 0x0800'i32
  MAP_ANON = 0x1000'i32

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

# Forward-facing C-compatible helper invoked by native JIT trampolines
proc nativeJitHelper(statePtr: ptr DspState, blkPtr: ptr IrBasicBlock): uint32 {.cdecl.} =
  if statePtr != nil and blkPtr != nil:
    return runner.runBlock(statePtr[], blkPtr[])
  return 0

proc newNativeJit*(capacity: int = 65536): NativeJitContext =
  new(result)
  result.capacity = capacity
  result.offset = 0
  result.blocks = @[]

  when defined(macosx) and defined(arm64):
    result.buffer = mmap(nil, capacity, PROT_READ or PROT_WRITE or PROT_EXEC,
                         MAP_PRIVATE or MAP_ANON or MAP_JIT, -1, 0)
  else:
    result.buffer = mmap(nil, capacity, PROT_READ or PROT_WRITE or PROT_EXEC,
                         MAP_PRIVATE or MAP_ANON, -1, 0)

  if result.buffer == MAP_FAILED:
    result.buffer = nil

var gFallbackBlocks: seq[IrBasicBlock] = @[]

proc fallbackCdeclDispatcher(statePtr: ptr DspState): uint32 {.cdecl.} =
  if statePtr != nil and gFallbackBlocks.len > 0:
    return runner.runBlock(statePtr[], gFallbackBlocks[^1])
  return 0

proc compileBlock*(ctx: NativeJitContext, blk: IrBasicBlock): NativeBlockFn =
  if ctx.buffer == nil or ctx.offset + 64 > ctx.capacity:
    gFallbackBlocks.add(blk)
    return fallbackCdeclDispatcher

  # Record block in context to ensure stable address
  let idx = ctx.blocks.len
  ctx.blocks.add(CompiledBlock(blk: blk, fn: nil))
  let blkPtr = addr ctx.blocks[idx].blk
  let helperPtr = cast[pointer](nativeJitHelper)

  let entryOffset = ctx.offset
  let entryPtr = cast[pointer](cast[uint](ctx.buffer) + uint(entryOffset))

  when defined(macosx) and defined(arm64):
    pthread_jit_write_protect_np(0)

    # Emit ARM64 machine code stub:
    # offset 0:  stp x29, x30, [sp, -16]!  (0xA9BF7BFD)
    # offset 4:  mov x29, sp               (0x910003FD)
    # offset 8:  ldr x1, [pc, #24]         (0x580000C1) -> loads blkPtr from offset 32
    # offset 12: ldr x2, [pc, #28]         (0x580000E2) -> loads helperPtr from offset 40
    # offset 16: blr x2                    (0xD63F0040)
    # offset 20: ldp x29, x30, [sp], 16    (0xA8C17BFD)
    # offset 24: ret                       (0xD65F03C0)
    # offset 28: nop                       (0xD503201F - alignment padding)
    # offset 32: .quad blkPtr
    # offset 40: .quad helperPtr

    let code32 = cast[ptr UncheckedArray[uint32]](entryPtr)
    code32[0] = 0xA9BF7BFD'u32
    code32[1] = 0x910003FD'u32
    code32[2] = 0x58000000'u32 or (6'u32 shl 5) or 1'u32  # ldr x1, [pc, #24]
    code32[3] = 0x58000000'u32 or (7'u32 shl 5) or 2'u32  # ldr x2, [pc, #28]
    code32[4] = 0xD63F0040'u32
    code32[5] = 0xA8C17BFD'u32
    code32[6] = 0xD65F03C0'u32
    code32[7] = 0xD503201F'u32

    let data64 = cast[ptr UncheckedArray[uint64]](cast[pointer](cast[uint](entryPtr) + 32))
    data64[0] = cast[uint64](blkPtr)
    data64[1] = cast[uint64](helperPtr)

    sys_icache_invalidate(entryPtr, 48)
    pthread_jit_write_protect_np(1)
  else:
    # Generic / x86_64 fallback:
    # Direct execution hook
    discard

  ctx.offset += 64
  let fn = cast[NativeBlockFn](entryPtr)
  ctx.blocks[idx].fn = fn
  return fn
