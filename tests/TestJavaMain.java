import genny.*;

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

    check(TestJava.nextColor(Color.BLUE) == Color.RED, "enum param and return");

    Tile tile = TestJava.moveTile(new Tile(new Vec(1f, 2f), Color.GREEN, true), 0.5f, -1f);
    check(tile.pos.x == 1.5f && tile.pos.y == 1f, "nested value object");
    check(tile.color == Color.GREEN && tile.solid, "value object enum and bool fields");

    try (Counter counter = new Counter(10)) {
      counter.bumpCounter();
      counter.bumpCounter();
      check(counter.getCount() == 12, "ref object constructor and proc");
      counter.setColor(Color.BLUE);
      check(counter.getColor() == Color.BLUE, "ref object enum field");
      check(counter.historyLen() == 2 && counter.historyGet(1) == 12, "ref object seq field");
    }

    try (SeqString w = TestJava.words()) {
      check(w.len() == 2 && w.get(1).equals("beta"), "seq[string]");
      w.add("gamma");
      check(w.get(2).equals("gamma"), "seq[string] add");
    }

    check(TestJava.failIfNegative(5) == 5, "raising proc, no error");
    try {
      TestJava.failIfNegative(-3);
      check(false, "raising proc throws");
    } catch (TestJavaException e) {
      check(e.getMessage().equals("negative: -3"), "raising proc throws");
    }

    for (int i = 0; i < 10000; i++) new Counter(i);
    System.gc();
    try { Thread.sleep(200); } catch (InterruptedException e) {}
    check(true, "Cleaner releases unclosed ref objects");

    System.out.println("All Java tests passed");
  }
}
