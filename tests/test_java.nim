import genny

const
  javaLongConst = 123
  javaDoubleConst = 1.5
  javaStringConst = "genny"

exportConsts:
  javaLongConst
  javaDoubleConst
  javaStringConst

proc addInts(a, b: int): int =
  a + b

proc addInt32s(a, b: int32): int32 =
  a + b

proc mulFloats(a, b: float32): float32 =
  a * b

proc mulDoubles(a, b: float): float =
  a * b

proc negate(a: bool): bool =
  not a

proc echoByte(a: byte): byte =
  a

proc greet(name: string): string =
  "Hello, " & name & "!"

proc helloWorld(): string =
  "Hello world from Nim!"

var callCount: int

proc bump() =
  inc callCount

proc getCallCount(): int =
  callCount

exportProcs:
  addInts
  addInt32s
  mulFloats
  mulDoubles
  negate
  echoByte
  greet
  helloWorld
  bump
  getCallCount

writeFiles("tests/generated_java", "testJava")

include generated_java/internal
