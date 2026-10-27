# dsp56300_nim - Clean-room MIT Nim implementation of Motorola DSP56300/DSP56311

const projectVersion* = "0.0.1"

const greetingMsg* = "hello from dsp56300_nim"

proc hello*(): string =
  ## Returns standard project greeting string.
  greetingMsg

proc add*(a, b: int): int =
  ## Adds two integers.
  a + b
