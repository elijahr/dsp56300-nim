import unittest
import dsp56300_nim

suite "dsp56300_nim":
  test "hello returns expected greeting":
    check hello() == "hello from dsp56300_nim"

  test "version present":
    check projectVersion == "0.0.1"
