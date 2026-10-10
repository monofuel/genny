import
  std/[macros, os, strformat, strutils],
  ../common

const gennyJavaPackage {.strdefine.} = "genny"

when not defined(noSignalHandler):
  # The JVM raises SIGSEGV on purpose (null checks, safepoints) and handles
  # it itself; Nim's handler would turn those into a process exit.
  {.error: "genny java: compile with -d:noSignalHandler, Nim's SIGSEGV handler breaks the JVM".}

type JavaType = object
  java, jni, sig, c: string

var
  javaMembers {.compiletime.}: string
  cProtos {.compiletime.}: string
  cWrappers {.compiletime.}: string
  cMethods {.compiletime.}: string

proc stripSink(sym: NimNode): NimNode =
  if sym.kind == nnkBracketExpr and sym[0].repr == "sink":
    sym[1]
  else:
    sym

proc isVoid(sym: NimNode): bool =
  sym.kind == nnkEmpty or sym.repr == "void"

proc javaType(sym: NimNode, supported: var bool): JavaType =
  supported = true
  let typ = sym.stripSink
  if typ.kind == nnkBracketExpr:
    supported = false
    return
  case typ.repr
  of "int", "int64", "uint", "uint64":
    JavaType(java: "long", jni: "jlong", sig: "J", c: "int64_t")
  of "int32", "uint32":
    JavaType(java: "int", jni: "jint", sig: "I", c: "int32_t")
  of "int16", "uint16":
    JavaType(java: "short", jni: "jshort", sig: "S", c: "int16_t")
  of "int8", "uint8", "byte":
    JavaType(java: "byte", jni: "jbyte", sig: "B", c: "int8_t")
  of "bool":
    JavaType(java: "boolean", jni: "jboolean", sig: "Z", c: "bool")
  of "float32":
    JavaType(java: "float", jni: "jfloat", sig: "F", c: "float")
  of "float", "float64":
    JavaType(java: "double", jni: "jdouble", sig: "D", c: "double")
  of "string":
    JavaType(java: "String", jni: "jstring", sig: "Ljava/lang/String;", c: "char *")
  else:
    supported = false
    JavaType()

proc javaClassName(lib: string): string =
  toCamelCase(toSnakeCase(lib))

proc exportConstJava*(sym: NimNode) =
  var supported: bool
  let t = javaType(sym.getTypeInst(), supported)
  if not supported:
    warning(&"genny java: skipping const {sym.repr}, unsupported type", sym)
    return
  var valueNode = sym.getImpl()[2]
  while valueNode.kind == nnkSym:
    valueNode = valueNode.getImpl()[2]
  var value = valueNode.repr
  case t.java
  of "long": value.add "L"
  of "float": value.add "f"
  of "short", "byte": value = &"({t.java}){value}"
  else: discard
  javaMembers.add &"  public static final {t.java} {toCapSnakeCase(sym.repr)} = {value};\n"

proc exportProcJava*(
  sym: NimNode,
  owner: NimNode = nil,
  prefixes: openarray[NimNode] = []
) =
  if owner != nil:
    warning(&"genny java: skipping {owner.repr}.{sym.repr}, object procs not supported yet", sym)
    return

  let
    procType = sym.getTypeInst()
    procParams = procType[0][1 .. ^1]
    procReturn = procType[0][0]
    apiName = "$lib_" & toSnakeCase(sym.repr)
    wrapperName = "genny_jni_" & toSnakeCase(sym.repr)

  var
    supported = true
    ok: bool
    params: seq[(string, JavaType)]
  for param in procParams:
    for i in 0 .. param.len - 3:
      let t = javaType(param[^2], ok)
      supported = supported and ok
      params.add((toSnakeCase(param[i].repr), t))
  var ret = JavaType(java: "void", jni: "void", sig: "V", c: "void")
  if not procReturn.isVoid:
    ret = javaType(procReturn, ok)
    supported = supported and ok
  if not supported:
    warning(&"genny java: skipping proc {sym.repr}, unsupported types", sym)
    return

  var
    javaParams, cProtoParams, jniParams, sig, callArgs, setup, cleanup: seq[string]
  for (name, t) in params:
    javaParams.add &"{t.java} {toVarCase(toCamelCase(name))}"
    cProtoParams.add &"{t.c} {name}"
    jniParams.add &"{t.jni} {name}"
    sig.add t.sig
    if t.java == "String":
      setup.add &"  const char *{name}_c = (*env)->GetStringUTFChars(env, {name}, NULL);\n"
      setup.add &"  if ({name}_c == NULL) return{(if ret.java == \"void\": \"\" else: \" 0\")};\n"
      cleanup.add &"  (*env)->ReleaseStringUTFChars(env, {name}, {name}_c);\n"
      callArgs.add &"(char *){name}_c"
    elif t.java == "boolean":
      callArgs.add &"{name} == JNI_TRUE"
    else:
      callArgs.add &"({t.c}){name}"

  javaMembers.add &"  public static native {ret.java} {sym.repr}({javaParams.join(\", \")});\n"

  cProtos.add &"extern {ret.c} {apiName}({cProtoParams.join(\", \")});\n"

  var allJniParams = @["JNIEnv *env", "jclass cls"]
  allJniParams.add jniParams
  cWrappers.add &"static {ret.jni} {wrapperName}({allJniParams.join(\", \")}) {{\n"
  cWrappers.add "  (void)cls;\n"
  if params.len == 0 or setup.len == 0:
    cWrappers.add "  (void)env;\n"
  cWrappers.add setup.join("")
  let call = &"{apiName}({callArgs.join(\", \")})"
  case ret.java
  of "void":
    cWrappers.add &"  {call};\n"
    cWrappers.add cleanup.join("")
  of "String":
    # TODO: under ARC/ORC the char* from the internal export points into a
    # Nim string that is already freed when it returns. NewStringUTF must copy
    # it before anything else allocates; revisit with a threadvar holder.
    cWrappers.add &"  {ret.c}genny_result = {call};\n"
    cWrappers.add cleanup.join("")
    cWrappers.add "  return (*env)->NewStringUTF(env, genny_result == NULL ? \"\" : genny_result);\n"
  of "boolean":
    cWrappers.add &"  {ret.jni} genny_result = {call} ? JNI_TRUE : JNI_FALSE;\n"
    cWrappers.add cleanup.join("")
    cWrappers.add "  return genny_result;\n"
  else:
    cWrappers.add &"  {ret.jni} genny_result = ({ret.jni}){call};\n"
    cWrappers.add cleanup.join("")
    cWrappers.add "  return genny_result;\n"
  cWrappers.add "}\n\n"

  cMethods.add &"  {{\"{sym.repr}\", \"({sig.join(\"\")}){ret.sig}\", (void *){wrapperName}}},\n"

proc writeJava*(dir, lib: string): NimNode =
  let
    className = javaClassName(lib)
    classPath = gennyJavaPackage.replace('.', '/') & "/" & className
    javaDir = dir / "java" / gennyJavaPackage.replace('.', '/')
    cPath = dir / (toSnakeCase(lib) & "_jni.c")
    javaHome = getEnv("JAVA_HOME")

  if javaHome == "":
    error("genny java: JAVA_HOME must be set to a JDK so jni.h can be found")

  createDir(javaDir)

  var java = ""
  java.add &"package {gennyJavaPackage};\n\n"
  java.add &"public final class {className} {{\n"
  java.add &"  private {className}() {{}}\n\n"
  java.add "  /** Loads the native library from an absolute path. */\n"
  java.add "  public static void load(String absolutePath) {\n"
  java.add "    System.load(absolutePath);\n"
  java.add "  }\n\n"
  java.add javaMembers
  java.add "}\n"
  writeFile(javaDir / (className & ".java"), java)

  var code = ""
  code.add "#include <jni.h>\n"
  code.add "#include <stdbool.h>\n"
  code.add "#include <stdint.h>\n\n"
  code.add "extern void NimMain(void);\n\n"
  code.add cProtos
  code.add "\n"
  code.add cWrappers
  code.add "static JNINativeMethod genny_jni_methods[] = {\n"
  code.add cMethods
  code.add "};\n\n"
  code.add "JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {\n"
  code.add "  (void)reserved;\n"
  code.add "  JNIEnv *env;\n"
  code.add "  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8) != JNI_OK) return JNI_ERR;\n"
  code.add "  NimMain();\n"
  code.add &"  jclass cls = (*env)->FindClass(env, \"{classPath}\");\n"
  code.add "  if (cls == NULL) return JNI_ERR;\n"
  code.add "  jint count = (jint)(sizeof(genny_jni_methods) / sizeof(genny_jni_methods[0]));\n"
  code.add "  if (count > 0 && (*env)->RegisterNatives(env, cls, genny_jni_methods, count) != 0) return JNI_ERR;\n"
  code.add "  return JNI_VERSION_1_8;\n"
  code.add "}\n"
  code = code.replace("$lib", toSnakeCase(lib))
  writeFile(cPath, code)

  result = newStmtList()
  let
    includeOpt = "-I" & (javaHome / "include")
    includePlatformOpt = "-I" & (javaHome / "include" / "linux")
    compilePath = cPath
  result.add quote do:
    {.passC: `includeOpt`.}
    {.passC: `includePlatformOpt`.}
    {.compile: `compilePath`.}
