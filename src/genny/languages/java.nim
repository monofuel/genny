import
  std/[macros, os, sets, strformat, strutils, tables, unicode],
  ../common

const gennyJavaPackage {.strdefine.} = "genny"

when not defined(noSignalHandler):
  # The JVM raises SIGSEGV on purpose (null checks, safepoints) and handles
  # it itself; Nim's handler would turn those into a process exit.
  {.error: "genny java: compile with -d:noSignalHandler, Nim's SIGSEGV handler breaks the JVM".}

type
  Kind = enum
    kVoid, kPrim, kString, kEnum, kValue, kRef, kBuffer, kUnsupported

  JType = object
    kind: Kind
    java: string       ## Type in the public Java API.
    native: string     ## Type in the `native` declaration.
    jni: string        ## C type of the JNI value.
    sig: string        ## JNI signature of `native`.
    publicSig: string  ## JNI signature of `java` (value object fields).
    c: string          ## C type of the Nim export.
    field: string      ## Get<X>Field / New<X> suffix for primitives.

const
  libClass = "$LibClass"
  # Nim passes object parameters larger than this by pointer unless they
  # are {.bycopy.}; the JNI wrappers pass value objects as C structs.
  maxByValueSize = 3 * 8
  javaKeywords = [
    "abstract", "assert", "boolean", "break", "byte", "case", "catch",
    "char", "class", "const", "continue", "default", "do", "double", "else",
    "enum", "extends", "false", "final", "finally", "float", "for", "goto",
    "if", "implements", "import", "instanceof", "int", "interface", "long",
    "native", "new", "null", "package", "private", "protected", "public",
    "return", "short", "static", "strictfp", "super", "switch",
    "synchronized", "this", "throw", "throws", "transient", "true", "try",
    "void", "volatile", "while", "yield", "_"
  ]

var
  libMembers {.compiletime.}: string
  classMembers {.compiletime.}: OrderedTable[string, string]
  classKinds {.compiletime.}: Table[string, Kind]
  enumCTypes {.compiletime.}: Table[string, string]
  enumEntries {.compiletime.}: OrderedTable[string, seq[(string, int)]]
  valueNames {.compiletime.}: HashSet[string]
  refNames {.compiletime.}: HashSet[string]
  javaSigs {.compiletime.}: HashSet[string]
  cTypes {.compiletime.}: string
  cProtos {.compiletime.}: string
  cHelpers {.compiletime.}: string
  cWrappers {.compiletime.}: string
  cMethods {.compiletime.}: string
  cOnLoad {.compiletime.}: string
  needsErrorBridge {.compiletime.}: bool
  needsStrings {.compiletime.}: bool

proc stripSink(sym: NimNode): NimNode =
  if sym.kind == nnkBracketExpr and sym[0].repr == "sink":
    sym[1]
  else:
    sym

proc isVoid(sym: NimNode): bool =
  sym.kind == nnkEmpty or sym.repr in ["void", "", "nil"]

proc classPath(name: string): string =
  gennyJavaPackage.replace('.', '/') & "/" & name

proc javaIdent(name: string): string =
  if name in javaKeywords: name & "_" else: name

proc javaName(snaked: string): string =
  ## Java identifier for a snake_case Nim name.
  javaIdent(toVarCase(toCamelCase(snaked)))

proc javaMethodName(sym: NimNode): string =
  ## Java method name for a Nim proc, or "" when there is none.
  let name = sym.repr.strip(chars = {'`'})
  if name.len == 0 or name[0] notin IdentStartChars:
    return ""
  for c in name:
    if c notin IdentChars:
      return ""
  javaIdent(name)

proc claim(className, name: string, params: seq[string]): bool =
  ## Reserves a Java method signature, false when it is already taken.
  let key = &"{className}.{name}({params.join(\",\")})"
  result = key notin javaSigs
  javaSigs.incl key

proc prim(java, jni, sig, c, field: string): JType =
  JType(kind: kPrim, java: java, native: java, jni: jni, sig: sig,
    publicSig: sig, c: c, field: field)

proc jtype(sym: NimNode): JType =
  let typ = sym.stripSink
  if typ.isVoid:
    return JType(kind: kVoid, java: "void", native: "void", jni: "void",
      sig: "V", c: "void")
  let name = typ.getName()
  if typ.kind == nnkBracketExpr:
    if typ[0].repr == "seq" and name in refNames:
      return JType(kind: kRef, java: name, native: "long", jni: "jlong",
        sig: "J", publicSig: &"L{classPath(name)};", c: "void *")
    return JType(kind: kUnsupported)
  if name in enumCTypes:
    return JType(kind: kEnum, java: name, native: "int", jni: "jint",
      sig: "I", publicSig: &"L{classPath(name)};", c: enumCTypes[name])
  if name in valueNames:
    return JType(kind: kValue, java: name, native: name, jni: "jobject",
      sig: &"L{classPath(name)};", publicSig: &"L{classPath(name)};", c: name)
  if name in refNames:
    return JType(kind: kRef, java: name, native: "long", jni: "jlong",
      sig: "J", publicSig: &"L{classPath(name)};", c: "void *")
  case name
  of "int": prim("long", "jlong", "J", "intptr_t", "Long")
  of "uint": prim("long", "jlong", "J", "uintptr_t", "Long")
  of "int64": prim("long", "jlong", "J", "int64_t", "Long")
  of "uint64": prim("long", "jlong", "J", "uint64_t", "Long")
  of "int32": prim("int", "jint", "I", "int32_t", "Int")
  of "uint32": prim("int", "jint", "I", "uint32_t", "Int")
  of "int16": prim("short", "jshort", "S", "int16_t", "Short")
  of "uint16": prim("short", "jshort", "S", "uint16_t", "Short")
  of "int8": prim("byte", "jbyte", "B", "int8_t", "Byte")
  of "uint8", "byte": prim("byte", "jbyte", "B", "uint8_t", "Byte")
  of "bool": prim("boolean", "jboolean", "Z", "bool", "Boolean")
  of "float32": prim("float", "jfloat", "F", "float", "Float")
  of "float", "float64": prim("double", "jdouble", "D", "double", "Double")
  of "pointer":
    JType(kind: kBuffer, java: "java.nio.ByteBuffer", native: "java.nio.ByteBuffer",
      jni: "jobject", sig: "Ljava/nio/ByteBuffer;",
      publicSig: "Ljava/nio/ByteBuffer;", c: "void *")
  of "string":
    JType(kind: kString, java: "java.lang.String", native: "java.lang.String",
      jni: "jstring", sig: "Ljava/lang/String;",
      publicSig: "Ljava/lang/String;", c: "char *")
  else:
    JType(kind: kUnsupported)

proc javaToNative(t: JType, expr: string): string =
  ## Converts a public Java value to the value passed to `native`.
  case t.kind
  of kEnum: &"{expr}.value"
  of kRef:
    if expr == "this": "this.handle$()"
    else: &"({expr} == null ? 0L : {expr}.handle$())"
  else: expr

proc nativeToJava(t: JType, expr: string): string =
  ## Converts a `native` return value to the public Java value.
  case t.kind
  of kEnum: &"{t.java}.fromValue({expr})"
  of kRef: &"{t.java}.wrap$({expr})"
  else: expr

proc javaClassName(lib: string): string =
  toCamelCase(toSnakeCase(lib))

proc addMember(className, code: string) =
  if className == libClass:
    libMembers.add code
  else:
    classMembers[className] = classMembers.getOrDefault(className) & code

proc emitNative(
  apiName: string,
  params: seq[(string, JType)],
  ret: JType,
  raises: bool
): string =
  ## Emits the JNI wrapper for one Nim export and returns the Java native
  ## method name, declared on the library class.
  doAssert ret.kind notin {kBuffer, kUnsupported}
  let
    nativeName = "n_" & apiName.replace("$lib_", "")
    wrapperName = "genny_jni_" & apiName.replace("$lib_", "")

  var javaParams, cProtoParams, jniParams, sig, callArgs: seq[string]
  var decls, setup, cleanup: string
  for i, (name, t) in params:
    let p = &"p{i}"
    javaParams.add &"{t.native} {p}"
    cProtoParams.add t.c
    jniParams.add &"{t.jni} {p}"
    sig.add t.sig
    case t.kind
    of kString:
      needsStrings = true
      decls.add &"  char *{p}_c = NULL;\n"
      setup.add &"  {p}_c = genny_utf8_from_jstring(env, {p});\n"
      setup.add &"  if ({p}_c == NULL) goto genny_done;\n"
      cleanup.add &"  free({p}_c);\n"
      callArgs.add &"{p}_c"
    of kValue:
      decls.add &"  {t.c} {p}_c;\n"
      setup.add &"  if (!genny_to_{t.c}(env, {p}, &{p}_c)) goto genny_done;\n"
      callArgs.add &"{p}_c"
    of kBuffer:
      decls.add &"  void *{p}_c = NULL;\n"
      setup.add &"  if ({p} != NULL) {{\n"
      setup.add &"    {p}_c = (*env)->GetDirectBufferAddress(env, {p});\n"
      setup.add &"    if ({p}_c == NULL) {{\n"
      setup.add "      genny_throw(env, \"java/lang/IllegalArgumentException\", \"pointer arguments must be direct ByteBuffers\");\n"
      setup.add "      goto genny_done;\n"
      setup.add "    }\n"
      setup.add "  }\n"
      callArgs.add &"{p}_c"
    of kPrim:
      callArgs.add(if t.java == "boolean": &"{p} == JNI_TRUE" else: &"({t.c}){p}")
    of kEnum:
      callArgs.add &"({t.c}){p}"
    of kRef:
      callArgs.add &"(void *)(intptr_t){p}"
    else:
      callArgs.add p

  libMembers.add &"  static native {ret.native} {nativeName}({javaParams.join(\", \")});\n"
  cProtos.add &"extern {ret.c} {apiName}({cProtoParams.join(\", \")});\n"

  var allJniParams = @["JNIEnv *env", "jclass cls"]
  allJniParams.add jniParams
  cWrappers.add &"static {ret.jni} JNICALL {wrapperName}({allJniParams.join(\", \")}) {{\n"
  case ret.kind
  of kVoid: discard
  of kString, kValue: cWrappers.add &"  {ret.jni} genny_ret = NULL;\n"
  else: cWrappers.add &"  {ret.jni} genny_ret = 0;\n"
  cWrappers.add decls
  cWrappers.add "  (void)env; (void)cls;\n"
  cWrappers.add setup
  let call = &"{apiName}({callArgs.join(\", \")})"
  cWrappers.add "  {\n"
  if ret.kind == kVoid:
    cWrappers.add &"    {call};\n"
  else:
    cWrappers.add &"    {ret.c} genny_result = {call};\n"
  var store = ""
  case ret.kind
  of kVoid: discard
  of kString:
    # TODO: under ARC/ORC the char* from the internal export points into a
    # Nim string that is already freed when it returns. It is copied here
    # before anything else allocates; revisit with a threadvar holder.
    needsStrings = true
    store = "genny_ret = genny_jstring_from_utf8(env, genny_result);"
  of kPrim:
    store =
      if ret.java == "boolean": "genny_ret = genny_result ? JNI_TRUE : JNI_FALSE;"
      else: &"genny_ret = ({ret.jni})genny_result;"
  of kEnum: store = "genny_ret = (jint)genny_result;"
  of kValue: store = &"genny_ret = genny_from_{ret.c}(env, genny_result);"
  of kRef: store = "genny_ret = (jlong)(intptr_t)genny_result;"
  else: discard
  if raises:
    needsErrorBridge = true
    needsStrings = true
    cWrappers.add "    if ($lib_check_error()) genny_raise(env);\n"
    if store != "":
      cWrappers.add &"    else {store}\n"
  elif store != "":
    cWrappers.add &"    {store}\n"
  cWrappers.add "  }\n"
  if "genny_done" in setup:
    cWrappers.add "genny_done:;\n"
  cWrappers.add cleanup
  if ret.kind != kVoid:
    cWrappers.add "  return genny_ret;\n"
  cWrappers.add "}\n\n"

  cMethods.add &"  {{\"{nativeName}\", \"({sig.join(\"\")}){ret.sig}\", (void *){wrapperName}}},\n"
  nativeName

proc javaMethod(
  signature, nativeName: string,
  args: seq[string],
  ret: JType,
  fences: seq[string],
  checks: seq[string] = @[]
): string =
  ## A public Java method that calls one native method. Pending releases
  ## run first, and ref objects stay reachable until the call returns.
  let call = &"{libClass}.{nativeName}({args.join(\", \")})"
  var lines = checks
  if ret.kind == kVoid:
    lines.add call & ";"
  else:
    lines.add &"return {nativeToJava(ret, call)};"
  result = &"  {signature} {{\n"
  result.add &"    {libClass}.releasePending();\n"
  if fences.len == 0:
    for line in lines:
      result.add &"    {line}\n"
  else:
    result.add "    try {\n"
    for line in lines:
      result.add &"      {line}\n"
    result.add "    } finally {\n"
    for fence in fences:
      result.add &"      java.lang.ref.Reference.reachabilityFence({fence});\n"
    result.add "    }\n"
  result.add "  }\n\n"

proc javaString(s: string): string =
  ## Java string literal; control characters use octal escapes because
  ## javac translates \u escapes before it reads string literals.
  result = "\""
  for rune in s.runes:
    let c = rune.int
    if c == '"'.ord:
      result.add "\\\""
    elif c == '\\'.ord:
      result.add "\\\\"
    elif c < 0x20 or c == 0x7F:
      result.add "\\" & toOct(c, 3)
    elif c < 0x7F:
      result.add chr(c)
    elif c > 0xFFFF:
      let v = c - 0x10000
      result.add "\\u" & toHex(0xD800 + (v shr 10), 4)
      result.add "\\u" & toHex(0xDC00 + (v and 0x3FF), 4)
    else:
      result.add "\\u" & toHex(c, 4)
  result.add "\""

proc wrapSigned(v: BiggestInt, bits: int): BiggestInt =
  ## Reinterprets the low `bits` bits of v as a signed integer.
  let span = 1'i64 shl bits
  result = v and (span - 1)
  if result >= span div 2:
    result -= span

proc javaLiteral(t: JType, v: NimNode): string =
  ## Java literal for a constant value node.
  case t.java
  of "java.lang.String": javaString(v.strVal)
  of "boolean": (if v.intVal != 0: "true" else: "false")
  of "long": $v.intVal & "L"
  of "int": $wrapSigned(v.intVal, 32)
  of "short": &"(short)({wrapSigned(v.intVal, 16)})"
  of "byte": &"(byte)({wrapSigned(v.intVal, 8)})"
  else:
    let
      f = v.floatVal
      box = if t.java == "float": "java.lang.Float" else: "java.lang.Double"
    if f != f:
      &"{box}.NaN"
    elif f == Inf:
      &"{box}.POSITIVE_INFINITY"
    elif f == NegInf:
      &"{box}.NEGATIVE_INFINITY"
    elif t.java == "float":
      $f & "f"
    else:
      $f

proc exportConstJava*(sym: NimNode) =
  let t = jtype(sym.getTypeInst())
  if t.kind notin {kPrim, kString}:
    warning(&"genny java: skipping const {sym.repr}, unsupported type", sym)
    return
  var valueNode = sym.getImpl()[2]
  while valueNode.kind == nnkSym:
    valueNode = valueNode.getImpl()[2]
  libMembers.add &"  public static final {t.java} {toCapSnakeCase(sym.repr)} = {javaLiteral(t, valueNode)};\n"

proc exportEnumJava*(sym: NimNode) =
  let name = sym.repr
  var
    entries: seq[(string, int)]
    next = 0
  for entry in sym.getImpl()[2][1 .. ^1]:
    var
      field = entry
      value = next
    if entry.kind == nnkEnumFieldDef:
      field = entry[0]
      case entry[1].kind
      of nnkIntLit .. nnkUInt64Lit:
        value = entry[1].intVal.int
      of nnkTupleConstr, nnkPar:
        value = entry[1][0].intVal.int
      else:
        discard
    if value < int32.low or value > int32.high:
      warning(&"genny java: skipping enum {name}, values must fit in a Java int", sym)
      return
    entries.add((toCapSnakeCase(field.repr), value))
    next = value + 1
  # Matches the C type Nim's code generator picks for the enum.
  enumCTypes[name] =
    if entries[0][1] < 0: "int32_t"
    else:
      case getSize(sym)
      of 1: "uint8_t"
      of 2: "uint16_t"
      of 8: "int64_t"
      else: "int32_t"
  enumEntries[name] = entries
  classKinds[name] = kEnum

proc exportProcJava*(
  sym: NimNode,
  owner: NimNode = nil,
  prefixes: openarray[NimNode] = []
) =
  let
    procType = sym.getTypeInst()
    procParams = procType[0][1 .. ^1]
    procReturn = procType[0][0]
    ret = jtype(procReturn)

  var apiName = "$lib_"
  if owner != nil:
    apiName.add &"{toSnakeCase(owner.getName())}_"
  for prefix in prefixes:
    apiName.add &"{toSnakeCase(prefix.getName())}_"
  apiName.add toSnakeCase(sym.repr)

  var
    supported = ret.kind notin {kUnsupported, kBuffer}
    params: seq[(string, JType)]
  for param in procParams:
    for i in 0 .. param.len - 3:
      let t = jtype(param[^2])
      supported = supported and t.kind != kUnsupported
      params.add((toSnakeCase(param[i].repr), t))
  if not supported:
    warning(&"genny java: skipping proc {sym.repr}, unsupported types", sym)
    return
  var methodName = javaMethodName(sym)
  if methodName == "":
    warning(&"genny java: skipping proc {sym.repr}, no Java name for it", sym)
    return

  let onType = owner != nil and params.len > 0
  var publicParams, publicTypes, args, fences: seq[string]
  for i, (name, t) in params:
    let jname = if i == 0 and onType: "this" else: javaName(name)
    if jname != "this":
      publicParams.add &"{t.java} {jname}"
      publicTypes.add t.java
    args.add javaToNative(t, jname)
    if t.kind == kRef:
      fences.add jname

  let
    className = if onType: owner.getName() else: libClass
    modifier = if onType: "public" else: "public static"
  if not claim(className, methodName, publicTypes):
    var renamed = methodName
    for prefix in prefixes:
      renamed.add toCamelCase(toSnakeCase(prefix.getName()))
    if renamed == methodName or not claim(className, renamed, publicTypes):
      error(&"genny java: {sym.repr} has the same Java signature as another exported method", sym)
    methodName = renamed

  let nativeName = emitNative(apiName, params, ret, sym.raises())
  addMember(className, javaMethod(
    &"{modifier} {ret.java} {methodName}({publicParams.join(\", \")})",
    nativeName, args, ret, fences))

proc fieldIdent(property: NimNode): NimNode =
  result = property
  while result.kind in {nnkPostfix, nnkPragmaExpr, nnkAccQuoted}:
    result = if result.kind == nnkPostfix: result[1] else: result[0]

proc valueLayoutProblem(sym: NimNode): string =
  ## Why the object cannot cross JNI as a plain C struct, or "".
  let impl = sym.getImpl()
  var pragmas: seq[string]
  if impl[0].kind == nnkPragmaExpr:
    for pragma in impl[0][1]:
      pragmas.add(if pragma.kind in {nnkExprColonExpr, nnkCall}: pragma[0].repr else: pragma.repr)
  let obj = impl[2]
  if obj.kind != nnkObjectTy:
    return "it is not a plain object"
  if obj[1].kind != nnkEmpty:
    return "inherited objects are not supported"
  for pragma in ["packed", "union", "byref", "inheritable"]:
    if pragma in pragmas:
      return &"{{.{pragma}.}} objects are not supported"
  if obj[2].kind == nnkRecList:
    for item in obj[2]:
      if item.kind != nnkIdentDefs:
        return "object variants are not supported"
  if "bycopy" notin pragmas and getSize(sym) > maxByValueSize:
    return &"Nim passes objects over {maxByValueSize} bytes by pointer, mark it {{.bycopy.}}"

proc emitValueConversions(name: string, fields: seq[(string, NimNode)]) =
  ## C helpers between the Java value class and the Nim struct.
  cTypes.add &"typedef struct {name} {{\n"
  for (fieldName, fieldType) in fields:
    cTypes.add &"  {jtype(fieldType).c} f_{fieldName};\n"
  cTypes.add &"}} {name};\n\n"

  cHelpers.add &"static jclass genny_class_{name};\n"
  cHelpers.add &"static jmethodID genny_init_{name};\n"
  for (fieldName, _) in fields:
    cHelpers.add &"static jfieldID genny_field_{name}_{fieldName};\n"

  cHelpers.add &"static int genny_to_{name}(JNIEnv *env, jobject o, {name} *r) {{\n"
  cHelpers.add "  memset(r, 0, sizeof(*r));\n"
  cHelpers.add &"  if (o == NULL) {{ genny_throw(env, \"java/lang/NullPointerException\", \"{name} is null\"); return 0; }}\n"
  for (fieldName, fieldType) in fields:
    let
      t = jtype(fieldType)
      fid = &"genny_field_{name}_{fieldName}"
    case t.kind
    of kPrim:
      if t.java == "boolean":
        cHelpers.add &"  r->f_{fieldName} = (*env)->GetBooleanField(env, o, {fid}) == JNI_TRUE;\n"
      else:
        cHelpers.add &"  r->f_{fieldName} = ({t.c})(*env)->Get{t.field}Field(env, o, {fid});\n"
    of kEnum:
      cHelpers.add &"  {{ jobject e = (*env)->GetObjectField(env, o, {fid});\n"
      cHelpers.add &"    if (e == NULL) {{ genny_throw(env, \"java/lang/NullPointerException\", \"{name}.{javaName(fieldName)} is null\"); return 0; }}\n"
      cHelpers.add &"    r->f_{fieldName} = ({t.c})(*env)->GetIntField(env, e, genny_enum_value_{t.java});\n"
      cHelpers.add "    (*env)->DeleteLocalRef(env, e); }\n"
    of kValue:
      cHelpers.add &"  {{ jobject v = (*env)->GetObjectField(env, o, {fid});\n"
      cHelpers.add &"    int ok = genny_to_{t.c}(env, v, &r->f_{fieldName});\n"
      cHelpers.add "    if (v != NULL) (*env)->DeleteLocalRef(env, v);\n"
      cHelpers.add "    if (!ok) return 0; }\n"
    else: discard
  cHelpers.add "  return 1;\n}\n\n"

  var ctorSig, ctorArgs, decls, setup, cleanup: string
  for (fieldName, fieldType) in fields:
    let t = jtype(fieldType)
    ctorSig.add t.publicSig
    case t.kind
    of kPrim:
      if t.java == "boolean":
        ctorArgs.add &", (jboolean)(v.f_{fieldName} ? JNI_TRUE : JNI_FALSE)"
      else:
        ctorArgs.add &", ({t.jni})v.f_{fieldName}"
    of kEnum:
      decls.add &"  jobject j_{fieldName} = NULL;\n"
      setup.add &"  j_{fieldName} = (*env)->CallStaticObjectMethod(env, genny_class_{t.java}, genny_from_value_{t.java}, (jint)v.f_{fieldName});\n"
      setup.add "  if ((*env)->ExceptionCheck(env)) goto genny_done;\n"
      cleanup.add &"  if (j_{fieldName} != NULL) (*env)->DeleteLocalRef(env, j_{fieldName});\n"
      ctorArgs.add &", j_{fieldName}"
    of kValue:
      decls.add &"  jobject j_{fieldName} = NULL;\n"
      setup.add &"  j_{fieldName} = genny_from_{t.c}(env, v.f_{fieldName});\n"
      setup.add &"  if (j_{fieldName} == NULL) goto genny_done;\n"
      cleanup.add &"  if (j_{fieldName} != NULL) (*env)->DeleteLocalRef(env, j_{fieldName});\n"
      ctorArgs.add &", j_{fieldName}"
    else: discard
  cHelpers.add &"static jobject genny_from_{name}(JNIEnv *env, {name} v) {{\n"
  cHelpers.add "  jobject r = NULL;\n"
  cHelpers.add decls
  cHelpers.add setup
  cHelpers.add &"  r = (*env)->NewObject(env, genny_class_{name}, genny_init_{name}{ctorArgs});\n"
  cHelpers.add "  if ((*env)->ExceptionCheck(env)) r = NULL;\n"
  if setup != "":
    cHelpers.add "genny_done:\n"
  cHelpers.add cleanup
  cHelpers.add "  return r;\n}\n\n"

  cOnLoad.add &"  if (!genny_load_class(env, \"{classPath(name)}\", &genny_class_{name})) return JNI_ERR;\n"
  cOnLoad.add &"  genny_init_{name} = (*env)->GetMethodID(env, genny_class_{name}, \"<init>\", \"({ctorSig})V\");\n"
  cOnLoad.add &"  if (genny_init_{name} == NULL) return JNI_ERR;\n"
  for (fieldName, fieldType) in fields:
    let t = jtype(fieldType)
    cOnLoad.add &"  genny_field_{name}_{fieldName} = (*env)->GetFieldID(env, genny_class_{name}, \"{javaName(fieldName)}\", \"{t.publicSig}\");\n"
    cOnLoad.add &"  if (genny_field_{name}_{fieldName} == NULL) return JNI_ERR;\n"

proc exportObjectJava*(sym: NimNode, constructor: NimNode) =
  let name = sym.repr
  let problem = valueLayoutProblem(sym)
  if problem != "":
    warning(&"genny java: skipping object {name}, {problem}", sym)
    return
  var
    fields: seq[(string, NimNode)]
    supported = true
  if sym.getImpl()[2][2].kind == nnkRecList:
    for identDefs in sym.getImpl()[2][2]:
      for property in identDefs[0 .. ^3]:
        let t = jtype(identDefs[^2])
        if t.kind notin {kPrim, kEnum, kValue}:
          supported = false
        fields.add((toSnakeCase(property.fieldIdent.repr), identDefs[^2]))
  if not supported or fields.len == 0:
    warning(&"genny java: skipping object {name}, only primitive, enum and object fields are supported", sym)
    return

  valueNames.incl name
  classKinds[name] = kValue
  emitValueConversions(name, fields)
  discard claim(name, "equals", @["java.lang.Object"])
  discard claim(name, "hashCode", @[])

  var code = ""
  var ctorParams, defaults, assigns, eqs, hashes: seq[string]
  for (fieldName, fieldType) in fields:
    let
      t = jtype(fieldType)
      jname = javaName(fieldName)
    code.add &"  public {t.java} {jname};\n"
    ctorParams.add &"{t.java} {jname}"
    assigns.add &"    this.{jname} = {jname};\n"
    case t.kind
    of kValue:
      defaults.add &"    this.{jname} = new {t.java}();\n"
      eqs.add &"java.util.Objects.equals({jname}, o.{jname})"
    of kEnum:
      defaults.add &"    this.{jname} = {t.java}.{enumEntries[t.java][0][0]};\n"
      eqs.add &"{jname} == o.{jname}"
    else:
      case t.java
      of "float": eqs.add &"java.lang.Float.compare({jname}, o.{jname}) == 0"
      of "double": eqs.add &"java.lang.Double.compare({jname}, o.{jname}) == 0"
      else: eqs.add &"{jname} == o.{jname}"
    hashes.add jname
  code.add &"\n  public {name}() {{\n"
  code.add defaults.join("")
  code.add "  }\n\n"
  code.add &"  public {name}({ctorParams.join(\", \")}) {{\n"
  code.add assigns.join("")
  code.add "  }\n\n"
  code.add "  @java.lang.Override public boolean equals(java.lang.Object other) {\n"
  code.add "    if (this == other) return true;\n"
  code.add &"    if (!(other instanceof {name})) return false;\n"
  code.add &"    {name} o = ({name})other;\n"
  code.add &"    return {eqs.join(\" && \")};\n"
  code.add "  }\n\n"
  code.add "  @java.lang.Override public int hashCode() {\n"
  code.add &"    return java.util.Objects.hash({hashes.join(\", \")});\n"
  code.add "  }\n\n"
  addMember(name, code)

  if constructor != nil:
    let
      ctorType = constructor.getTypeInst()
      ret = jtype(sym)
    var
      params: seq[(string, JType)]
      supported = true
    for param in ctorType[0][1 .. ^1]:
      let t = jtype(param[1])
      supported = supported and t.kind != kUnsupported
      params.add((param[0].repr.split('`')[0], t))
    let methodName = javaMethodName(constructor)
    if not supported or methodName == "":
      warning(&"genny java: skipping constructor of {name}, unsupported types", sym)
      return
    var publicParams, publicTypes, args, fences: seq[string]
    for (pname, t) in params:
      let jname = javaName(pname)
      publicParams.add &"{t.java} {jname}"
      publicTypes.add t.java
      args.add javaToNative(t, jname)
      if t.kind == kRef:
        fences.add jname
    if not claim(name, methodName, publicTypes):
      error(&"genny java: constructor {constructor.repr} has the same Java signature as another method of {name}", sym)
    let nativeName = emitNative(&"$lib_{toSnakeCase(name)}", params, ret, false)
    addMember(name, javaMethod(
      &"public static {name} {methodName}({publicParams.join(\", \")})",
      nativeName, args, ret, fences))

proc emitHandleClass(name, unrefApi: string) =
  ## Members shared by ref objects and seqs: the handle, wrapping and
  ## releasing. The Cleaner only queues the release; it runs on the next
  ## call into the library, so Nim refcounts are only touched by threads
  ## that call the library.
  let unrefNative = emitNative(unrefApi, @[("x", JType(kind: kRef,
    native: "long", jni: "jlong", sig: "J", c: "void *"))],
    jtype(newEmptyNode()), false)
  discard claim(name, "close", @[])
  var code = ""
  code.add "  private long handle$;\n"
  code.add "  private final java.lang.ref.Cleaner.Cleanable cleanable$;\n\n"
  code.add &"  private {name}(long handle, java.lang.Void unused) {{\n"
  code.add &"    if (handle == 0L) throw new java.lang.IllegalStateException(\"{name} is nil\");\n"
  code.add "    this.handle$ = handle;\n"
  code.add &"    this.cleanable$ = {libClass}.CLEANER$.register(this, new {libClass}.Release$(handle, {libClass}::{unrefNative}));\n"
  code.add "  }\n\n"
  code.add &"  static {name} wrap$(long handle) {{\n"
  code.add &"    return handle == 0L ? null : new {name}(handle, null);\n"
  code.add "  }\n\n"
  code.add "  long handle$() {\n"
  code.add &"    if (handle$ == 0L) throw new java.lang.IllegalStateException(\"{name} is closed\");\n"
  code.add "    return handle$;\n"
  code.add "  }\n\n"
  code.add "  /** Releases the Nim object. Using this object afterwards throws IllegalStateException. */\n"
  code.add "  @java.lang.Override public void close() {\n"
  code.add "    if (handle$ == 0L) return;\n"
  code.add "    handle$ = 0L;\n"
  code.add "    cleanable$.clean();\n"
  code.add &"    {libClass}.releasePending();\n"
  code.add "  }\n\n"
  addMember(name, code)

proc emitConstructor(name, apiName: string, params: seq[(string, JType)], raises: bool) =
  ## Public Java constructor backed by a Nim proc returning a new handle.
  var publicParams, publicTypes, args, fences: seq[string]
  for (pname, t) in params:
    let jname = javaName(pname)
    publicParams.add &"{t.java} {jname}"
    publicTypes.add t.java
    args.add javaToNative(t, jname)
    if t.kind == kRef:
      fences.add jname
  if not claim(name, "create$", publicTypes):
    error(&"genny java: {name} has more than one constructor")
  let nativeName = emitNative(apiName, params, JType(kind: kRef, native: "long",
    jni: "jlong", sig: "J", c: "void *"), raises)
  var names: seq[string]
  for (pname, _) in params:
    names.add javaName(pname)
  var code = &"  public {name}({publicParams.join(\", \")}) {{\n"
  code.add &"    this(create$({names.join(\", \")}), null);\n"
  code.add "  }\n\n"
  code.add javaMethod(&"private static long create$({publicParams.join(\", \")})",
    nativeName, args, JType(kind: kPrim, java: "long"), fences)
  addMember(name, code)

proc emitSeqAccessors(className, prefix, methodPrefix: string, selfType, entry: JType) =
  ## len/get/set/add/delete/clear for a seq or a seq field.
  let
    index = jtype(ident"int")
    voidT = jtype(newEmptyNode())
    self = ("s", selfType)
    entryFences = if entry.kind == kRef: @["this", "v"] else: @["this"]
  proc name(op: string): string =
    if methodPrefix == "": op else: methodPrefix & op.capitalizeAscii()
  proc claimed(op: string, params: seq[string]): string =
    result = name(op)
    if not claim(className, result, params):
      error(&"genny java: {className}.{result} is generated for a seq but is already taken")
  let
    lenNative = emitNative(prefix & "_len", @[self], index, false)
    bounds = @[
      &"long length$ = {libClass}.{lenNative}(this.handle$());",
      "if (i < 0 || i >= length$) throw new java.lang.IndexOutOfBoundsException(\"Index \" + i + \" out of bounds for length \" + length$);"
    ]
  var code = ""
  code.add javaMethod(&"public long {claimed(\"len\", @[])}()", lenNative,
    @["this.handle$()"], index, @["this"])
  var n = emitNative(prefix & "_get", @[self, ("i", index)], entry, false)
  code.add javaMethod(&"public {entry.java} {claimed(\"get\", @[\"long\"])}(long i)", n,
    @["this.handle$()", "i"], entry, @["this"], bounds)
  n = emitNative(prefix & "_set", @[self, ("i", index), ("v", entry)], voidT, false)
  code.add javaMethod(&"public void {claimed(\"set\", @[\"long\", entry.java])}(long i, {entry.java} v)", n,
    @["this.handle$()", "i", javaToNative(entry, "v")], voidT, entryFences, bounds)
  n = emitNative(prefix & "_add", @[self, ("v", entry)], voidT, false)
  code.add javaMethod(&"public void {claimed(\"add\", @[entry.java])}({entry.java} v)", n,
    @["this.handle$()", javaToNative(entry, "v")], voidT, entryFences)
  n = emitNative(prefix & "_delete", @[self, ("i", index)], voidT, false)
  code.add javaMethod(&"public void {claimed(\"delete\", @[\"long\"])}(long i)", n,
    @["this.handle$()", "i"], voidT, @["this"], bounds)
  n = emitNative(prefix & "_clear", @[self], voidT, false)
  code.add javaMethod(&"public void {claimed(\"clear\", @[])}()", n,
    @["this.handle$()"], voidT, @["this"])
  addMember(className, code)

proc exportRefObjectJava*(
  sym: NimNode,
  fields: seq[(string, NimNode)],
  constructor: NimNode
) =
  let
    name = sym.repr
    snaked = toSnakeCase(name)
  refNames.incl name
  classKinds[name] = kRef
  let self = jtype(sym)
  emitHandleClass(name, &"$lib_{snaked}_unref")

  if constructor != nil:
    let ctorType = constructor.getTypeInst()
    var params: seq[(string, JType)]
    var supported = true
    for param in ctorType[0][1 .. ^1]:
      let t = jtype(param[1])
      supported = supported and t.kind != kUnsupported
      params.add((param[0].repr.split('`')[0], t))
    var publicTypes: seq[string]
    for (_, t) in params:
      publicTypes.add t.java
    if not supported:
      warning(&"genny java: skipping constructor of {name}, unsupported types", sym)
    elif publicTypes == @["long", "java.lang.Void"]:
      error(&"genny java: constructor of {name} clashes with the internal constructor", sym)
    else:
      emitConstructor(name, &"$lib_{toSnakeCase(constructor.repr)}", params,
        constructor.raises())

  for (fieldName, fieldType) in fields:
    let fieldSnaked = toSnakeCase(fieldName)
    if fieldType.kind == nnkBracketExpr:
      let entry = jtype(fieldType[1])
      if entry.kind in {kUnsupported, kString, kBuffer}:
        warning(&"genny java: skipping field {name}.{fieldName}, unsupported seq entry type", sym)
        continue
      emitSeqAccessors(name, &"$lib_{snaked}_{fieldSnaked}", fieldName, self, entry)
      continue
    let t = jtype(fieldType)
    if t.kind in {kUnsupported, kBuffer}:
      warning(&"genny java: skipping field {name}.{fieldName}, unsupported type", sym)
      continue
    let
      cap = fieldName.capitalizeAscii()
      fences = if t.kind == kRef: @["this", "v"] else: @["this"]
    if not claim(name, "get" & cap, @[]) or not claim(name, "set" & cap, @[t.java]):
      error(&"genny java: accessors of {name}.{fieldName} clash with another method", sym)
    let
      getter = emitNative(&"$lib_{snaked}_get_{fieldSnaked}", @[("o", self)], t, false)
      setter = emitNative(&"$lib_{snaked}_set_{fieldSnaked}",
        @[("o", self), ("v", t)], jtype(newEmptyNode()), false)
    var code = ""
    code.add javaMethod(&"public {t.java} get{cap}()", getter,
      @["this.handle$()"], t, @["this"])
    code.add javaMethod(&"public void set{cap}({t.java} v)", setter,
      @["this.handle$()", javaToNative(t, "v")], jtype(newEmptyNode()), fences)
    addMember(name, code)

proc exportSeqJava*(sym: NimNode) =
  let
    name = sym.getSeqName()
    snaked = toSnakeCase(name)
  refNames.incl name
  classKinds[name] = kRef
  let
    self = jtype(sym)
    entry = jtype(sym[1])
  emitHandleClass(name, &"$lib_{snaked}_unref")
  emitConstructor(name, &"$lib_new_{snaked}", @[], false)
  if entry.kind in {kUnsupported, kBuffer}:
    warning(&"genny java: skipping accessors of {name}, unsupported entry type", sym)
    return
  emitSeqAccessors(name, &"$lib_{snaked}", "", self, entry)

const stringHelpers = """
static char *genny_utf8_from_jstring(JNIEnv *env, jstring s) {
  jsize n = s == NULL ? 0 : (*env)->GetStringLength(env, s);
  char *out = (char *)malloc((size_t)n * 3 + 1);
  size_t k = 0;
  if (out == NULL) {
    genny_throw(env, "java/lang/OutOfMemoryError", "genny: string conversion");
    return NULL;
  }
  if (n > 0) {
    const jchar *u = (*env)->GetStringCritical(env, s, NULL);
    jsize i;
    if (u == NULL) {
      free(out);
      if (!(*env)->ExceptionCheck(env)) genny_throw(env, "java/lang/OutOfMemoryError", "genny: string conversion");
      return NULL;
    }
    for (i = 0; i < n; i++) {
      uint32_t c = u[i];
      if (c >= 0xD800 && c < 0xDC00 && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] < 0xE000) {
        c = 0x10000 + ((c - 0xD800) << 10) + (u[i + 1] - 0xDC00);
        i++;
      } else if (c >= 0xD800 && c < 0xE000) {
        c = 0xFFFD;
      }
      if (c < 0x80) {
        out[k++] = (char)c;
      } else if (c < 0x800) {
        out[k++] = (char)(0xC0 | (c >> 6));
        out[k++] = (char)(0x80 | (c & 0x3F));
      } else if (c < 0x10000) {
        out[k++] = (char)(0xE0 | (c >> 12));
        out[k++] = (char)(0x80 | ((c >> 6) & 0x3F));
        out[k++] = (char)(0x80 | (c & 0x3F));
      } else {
        out[k++] = (char)(0xF0 | (c >> 18));
        out[k++] = (char)(0x80 | ((c >> 12) & 0x3F));
        out[k++] = (char)(0x80 | ((c >> 6) & 0x3F));
        out[k++] = (char)(0x80 | (c & 0x3F));
      }
    }
    (*env)->ReleaseStringCritical(env, s, u);
  }
  out[k] = 0;
  return out;
}

static jstring genny_jstring_from_utf8(JNIEnv *env, const char *s) {
  jchar small[256];
  jchar *buf = small;
  const unsigned char *p = (const unsigned char *)(s == NULL ? "" : s);
  size_t len = strlen((const char *)p), i = 0, k = 0;
  jstring r;
  if (len > sizeof(small) / sizeof(small[0])) {
    buf = (jchar *)malloc(len * sizeof(jchar));
    if (buf == NULL) {
      genny_throw(env, "java/lang/OutOfMemoryError", "genny: string conversion");
      return NULL;
    }
  }
  while (i < len) {
    uint32_t c = p[i];
    int extra = c < 0x80 ? 0 : c < 0xC2 ? -1 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : c < 0xF5 ? 3 : -1;
    int j;
    if (extra > 0) {
      if (i + (size_t)extra >= len) {
        extra = -1;
      } else {
        c &= 0x3F >> extra;
        for (j = 1; j <= extra; j++) {
          if ((p[i + j] & 0xC0) != 0x80) { extra = -1; break; }
          c = (c << 6) | (p[i + j] & 0x3F);
        }
        if (extra == 2 && (c < 0x800 || (c >= 0xD800 && c < 0xE000))) extra = -1;
        if (extra == 3 && (c < 0x10000 || c > 0x10FFFF)) extra = -1;
      }
    }
    if (extra < 0) {
      buf[k++] = 0xFFFD;
      i++;
      continue;
    }
    i += (size_t)extra + 1;
    if (c >= 0x10000) {
      c -= 0x10000;
      buf[k++] = (jchar)(0xD800 + (c >> 10));
      buf[k++] = (jchar)(0xDC00 + (c & 0x3FF));
    } else {
      buf[k++] = (jchar)c;
    }
  }
  r = (*env)->NewString(env, buf, (jsize)k);
  if (buf != small) free(buf);
  return r;
}

"""

proc writeJava*(dir, lib: string): NimNode =
  let
    className = javaClassName(lib)
    javaDir = dir / "java" / gennyJavaPackage.replace('.', '/')
    cPath = dir / (toSnakeCase(lib) & "_jni.c")
    javaHome = getEnv("JAVA_HOME")
    exceptionClass = className & "Exception"
    # With --app:lib Nim initializes itself when the library is loaded.
    nimInitializes = appType == "lib" and not compileOption("noMain")

  if javaHome == "":
    error("genny java: JAVA_HOME must be set to a JDK so jni.h can be found")
  for name in classKinds.keys:
    if name in [className, exceptionClass]:
      error(&"genny java: type {name} clashes with the generated {name}.java")

  createDir(javaDir)

  proc header(): string =
    &"package {gennyJavaPackage};\n\n"

  var java = header()
  java.add &"public final class {className} {{\n"
  java.add &"  private {className}() {{}}\n\n"
  java.add "  static final java.lang.ref.Cleaner CLEANER$ = java.lang.ref.Cleaner.create();\n"
  java.add &"  private static final java.util.concurrent.ConcurrentLinkedQueue<Release$> PENDING$ =\n"
  java.add "    new java.util.concurrent.ConcurrentLinkedQueue<>();\n\n"
  java.add "  static final class Release$ implements java.lang.Runnable {\n"
  java.add "    private final long handle;\n"
  java.add "    private final java.util.function.LongConsumer unref;\n\n"
  java.add "    Release$(long handle, java.util.function.LongConsumer unref) {\n"
  java.add "      this.handle = handle;\n"
  java.add "      this.unref = unref;\n"
  java.add "    }\n\n"
  java.add "    @java.lang.Override public void run() { PENDING$.add(this); }\n"
  java.add "  }\n\n"
  java.add "  /** Loads the native library from an absolute path. */\n"
  java.add "  public static void load(java.lang.String absolutePath) {\n"
  java.add "    java.lang.System.load(absolutePath);\n"
  java.add "  }\n\n"
  java.add "  /** Releases Nim objects whose Java wrappers were garbage collected. Every call into the library does this first. */\n"
  java.add "  public static void releasePending() {\n"
  java.add "    Release$ r;\n"
  java.add "    while ((r = PENDING$.poll()) != null) r.unref.accept(r.handle);\n"
  java.add "  }\n\n"
  java.add libMembers
  java.add "}\n"
  writeFile(javaDir / (className & ".java"), java.replace(libClass, className))

  var exc = header()
  exc.add &"public class {exceptionClass} extends java.lang.RuntimeException {{\n"
  exc.add "  private static final long serialVersionUID = 1L;\n\n"
  exc.add &"  public {exceptionClass}(java.lang.String message) {{ super(message); }}\n"
  exc.add "}\n"
  writeFile(javaDir / (exceptionClass & ".java"), exc)

  for name, entries in enumEntries:
    var code = header()
    var values, cases: seq[string]
    for (entry, value) in entries:
      values.add &"{entry}({value})"
      cases.add &"      case {value}: return {entry};\n"
    code.add &"public enum {name} {{\n"
    code.add "  " & values.join(", ") & ";\n\n"
    code.add "  public final int value;\n\n"
    code.add &"  {name}(int value) {{ this.value = value; }}\n\n"
    code.add &"  static {name} fromValue(int value) {{\n"
    code.add "    switch (value) {\n"
    code.add cases.join("")
    code.add &"      default: throw new java.lang.IllegalArgumentException(\"{name} has no value \" + value);\n"
    code.add "    }\n"
    code.add "  }\n"
    code.add "}\n"
    writeFile(javaDir / (name & ".java"), code)

  for name, members in classMembers:
    var code = header()
    case classKinds.getOrDefault(name, kRef)
    of kValue:
      code.add &"public final class {name} {{\n"
    else:
      code.add &"public final class {name} implements java.lang.AutoCloseable {{\n"
    code.add members
    code.add "}\n"
    writeFile(javaDir / (name & ".java"), code.replace(libClass, className))

  var code = ""
  code.add "#include <jni.h>\n"
  code.add "#include <stdbool.h>\n"
  code.add "#include <stdint.h>\n"
  code.add "#include <stdlib.h>\n"
  code.add "#include <string.h>\n\n"
  if not nimInitializes:
    code.add "extern void NimMain(void);\n\n"
  if needsErrorBridge:
    code.add "extern bool $lib_check_error(void);\n"
    code.add "extern char *$lib_take_error(void);\n"
  code.add "static jclass genny_exception_class;\n"
  code.add "static jmethodID genny_exception_init;\n"
  for name in enumEntries.keys:
    code.add &"static jclass genny_class_{name};\n"
    code.add &"static jmethodID genny_from_value_{name};\n"
    code.add &"static jfieldID genny_enum_value_{name};\n"
  code.add "\n"
  code.add "static int genny_load_class(JNIEnv *env, const char *name, jclass *out) {\n"
  code.add "  jclass local = (*env)->FindClass(env, name);\n"
  code.add "  if (local == NULL) return 0;\n"
  code.add "  *out = (jclass)(*env)->NewGlobalRef(env, local);\n"
  code.add "  (*env)->DeleteLocalRef(env, local);\n"
  code.add "  return *out != NULL;\n"
  code.add "}\n\n"
  code.add "static void genny_throw(JNIEnv *env, const char *name, const char *message) {\n"
  code.add "  jclass c = (*env)->FindClass(env, name);\n"
  code.add "  if (c == NULL) return;\n"
  code.add "  (*env)->ThrowNew(env, c, message);\n"
  code.add "  (*env)->DeleteLocalRef(env, c);\n"
  code.add "}\n\n"
  if needsStrings:
    code.add stringHelpers
  if needsErrorBridge:
    code.add "static void genny_raise(JNIEnv *env) {\n"
    code.add "  char *message = $lib_take_error();\n"
    code.add "  jstring jmessage = genny_jstring_from_utf8(env, message == NULL ? \"error\" : message);\n"
    code.add "  jthrowable e;\n"
    code.add "  if (jmessage == NULL) return;\n"
    code.add "  e = (jthrowable)(*env)->NewObject(env, genny_exception_class, genny_exception_init, jmessage);\n"
    code.add "  (*env)->DeleteLocalRef(env, jmessage);\n"
    code.add "  if ((*env)->ExceptionCheck(env)) return;\n"
    code.add "  (*env)->Throw(env, e);\n"
    code.add "  (*env)->DeleteLocalRef(env, e);\n"
    code.add "}\n\n"
  code.add cTypes
  code.add cProtos
  code.add "\n"
  code.add cHelpers
  code.add cWrappers
  code.add "static JNINativeMethod genny_jni_methods[] = {\n"
  code.add cMethods
  code.add "};\n\n"
  code.add "JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {\n"
  code.add "  JNIEnv *env;\n"
  code.add "  jclass cls;\n"
  code.add "  jint registered;\n"
  code.add "  (void)reserved;\n"
  code.add "  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8) != JNI_OK) return JNI_ERR;\n"
  if not nimInitializes:
    code.add "  NimMain();\n"
  code.add &"  if (!genny_load_class(env, \"{classPath(exceptionClass)}\", &genny_exception_class)) return JNI_ERR;\n"
  code.add "  genny_exception_init = (*env)->GetMethodID(env, genny_exception_class, \"<init>\", \"(Ljava/lang/String;)V\");\n"
  code.add "  if (genny_exception_init == NULL) return JNI_ERR;\n"
  for name in enumEntries.keys:
    code.add &"  if (!genny_load_class(env, \"{classPath(name)}\", &genny_class_{name})) return JNI_ERR;\n"
    code.add &"  genny_from_value_{name} = (*env)->GetStaticMethodID(env, genny_class_{name}, \"fromValue\", \"(I)L{classPath(name)};\");\n"
    code.add &"  if (genny_from_value_{name} == NULL) return JNI_ERR;\n"
    code.add &"  genny_enum_value_{name} = (*env)->GetFieldID(env, genny_class_{name}, \"value\", \"I\");\n"
    code.add &"  if (genny_enum_value_{name} == NULL) return JNI_ERR;\n"
  code.add cOnLoad
  code.add &"  cls = (*env)->FindClass(env, \"{classPath(className)}\");\n"
  code.add "  if (cls == NULL) return JNI_ERR;\n"
  code.add "  registered = (*env)->RegisterNatives(env, cls, genny_jni_methods,\n"
  code.add "    (jint)(sizeof(genny_jni_methods) / sizeof(genny_jni_methods[0])));\n"
  code.add "  (*env)->DeleteLocalRef(env, cls);\n"
  code.add "  if (registered != 0) return JNI_ERR;\n"
  code.add "  return JNI_VERSION_1_8;\n"
  code.add "}\n"
  code = code.replace("$lib", toSnakeCase(lib))
  writeFile(cPath, code)

  let platformInclude =
    when defined(windows): "win32"
    elif defined(macosx): "darwin"
    elif defined(freebsd): "freebsd"
    elif defined(openbsd): "openbsd"
    else: "linux"
  result = newStmtList()
  let
    includeOpt = "-I" & quoteShell(javaHome / "include")
    includePlatformOpt = "-I" & quoteShell(javaHome / "include" / platformInclude)
    compilePath = cPath
  result.add quote do:
    {.passC: `includeOpt`.}
    {.passC: `includePlatformOpt`.}
    {.compile: `compilePath`.}
