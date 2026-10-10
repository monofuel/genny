import genny.TestJava;

public class TestJavaMain {
  static void check(boolean ok, String what) {
    if (!ok) throw new AssertionError(what);
    System.out.println("ok " + what);
  }

  public static void main(String[] args) {
    TestJava.load(new java.io.File(args[0]).getAbsolutePath());

    check(TestJava.JAVA_LONG_CONST == 123L, "long const");
    check(TestJava.JAVA_DOUBLE_CONST == 1.5, "double const");
    check(TestJava.JAVA_STRING_CONST.equals("genny"), "string const");

    check(TestJava.addInts(40, 2) == 42, "addInts");
    check(TestJava.addInts(Long.MAX_VALUE - 1, 1) == Long.MAX_VALUE, "addInts 64-bit");
    check(TestJava.addInt32s(1, 2) == 3, "addInt32s");
    check(TestJava.mulFloats(1.5f, 2f) == 3f, "mulFloats");
    check(TestJava.mulDoubles(1.5, 2) == 3.0, "mulDoubles");
    check(TestJava.negate(true) == false, "negate true");
    check(TestJava.negate(false) == true, "negate false");
    check(TestJava.echoByte((byte)7) == 7, "echoByte");
    check(TestJava.greet("Java").equals("Hello, Java!"), "greet");
    check(TestJava.helloWorld().equals("Hello world from Nim!"), "helloWorld");

    for (int i = 0; i < 3; i++) TestJava.bump();
    check(TestJava.getCallCount() == 3, "void proc + state");

    System.out.println("All Java tests passed");
  }
}
