import
  std/[macros, os, sets, strformat, strutils, tables],
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

const libClass = "$LibClass"

var
  libMembers {.compiletime.}: string
  classMembers {.compiletime.}: OrderedTable[string, string]
  classKinds {.compiletime.}: Table[string, Kind]
  enumNames {.compiletime.}: HashSet[string]
  enumSizes {.compiletime.}: Table[string, int]
  enumValues {.compiletime.}: Table[string, seq[string]]
  valueNames {.compiletime.}: HashSet[string]
  valueFields {.compiletime.}: Table[string, seq[(string, NimNode)]]
  refNames {.compiletime.}: HashSet[string]
  cTypes {.compiletime.}: string
  cProtos {.compiletime.}: string
  cHelpers {.compiletime.}: string
  cWrappers {.compiletime.}: string
  cMethods {.compiletime.}: string
  cOnLoad {.compiletime.}: string
  needsErrorBridge {.compiletime.}: bool

proc stripSink(sym: NimNode): NimNode =
  if sym.kind == nnkBracketExpr and sym[0].repr == "sink":
    sym[1]
  else:
    sym

proc isVoid(sym: NimNode): bool =
  sym.kind == nnkEmpty or sym.repr in ["void", "", "nil"]

proc classPath(name: string): string =
  gennyJavaPackage.replace('.', '/') & "/" & name

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
  if name in enumNames:
    let c = if enumSizes[name] <= 1: "uint8_t" else: "uint16_t"
    return JType(kind: kEnum, java: name, native: "int", jni: "jint",
      sig: "I", publicSig: &"L{classPath(name)};", c: c)
  if name in valueNames:
    return JType(kind: kValue, java: name, native: name, jni: "jobject",
      sig: &"L{classPath(name)};", publicSig: &"L{classPath(name)};", c: name)
  if name in refNames:
    return JType(kind: kRef, java: name, native: "long", jni: "jlong",
      sig: "J", publicSig: &"L{classPath(name)};", c: "void *")
  case name
  of "int", "int64", "uint", "uint64":
    prim("long", "jlong", "J", "int64_t", "Long")
  of "int32", "uint32":
    prim("int", "jint", "I", "int32_t", "Int")
  of "int16", "uint16":
    prim("short", "jshort", "S", "int16_t", "Short")
  of "int8", "uint8", "byte":
    prim("byte", "jbyte", "B", "int8_t", "Byte")
  of "bool":
    prim("boolean", "jboolean", "Z", "bool", "Boolean")
  of "float32":
    prim("float", "jfloat", "F", "float", "Float")
  of "float", "float64":
    prim("double", "jdouble", "D", "double", "Double")
  of "pointer":
    JType(kind: kBuffer, java: "java.nio.ByteBuffer", native: "java.nio.ByteBuffer",
      jni: "jobject", sig: "Ljava/nio/ByteBuffer;",
      publicSig: "Ljava/nio/ByteBuffer;", c: "void *")
  of "string":
    JType(kind: kString, java: "String", native: "String", jni: "jstring",
      sig: "Ljava/lang/String;", publicSig: "Ljava/lang/String;", c: "char *")
  else:
    JType(kind: kUnsupported)

proc javaToNative(t: JType, expr: string): string =
  ## Converts a public Java value to the value passed to `native`.
  case t.kind
  of kEnum: &"{expr}.ordinal()"
  of kRef: &"({expr} == null ? 0L : {expr}.handle)"
  else: expr

proc nativeToJava(t: JType, expr: string): string =
  ## Converts a `native` return value to the public Java value.
  case t.kind
  of kEnum: &"{t.java}.fromOrdinal({expr})"
  of kRef: &"{t.java}.wrap({expr})"
  else: expr

proc zeroReturn(t: JType): string =
  case t.kind
  of kVoid: "return;"
  of kString, kValue: "return NULL;"
  else: "return 0;"

proc cArg(t: JType, name: string, setup, cleanup: var string): string =
  ## Converts a JNI argument to the C value the Nim export takes.
  case t.kind
  of kString:
    setup.add &"  const char *{name}_c = {name} == NULL ? \"\" : (*env)->GetStringUTFChars(env, {name}, NULL);\n"
    cleanup.add &"  if ({name} != NULL) (*env)->ReleaseStringUTFChars(env, {name}, {name}_c);\n"
    &"(char *){name}_c"
  of kPrim:
    if t.java == "boolean": &"{name} == JNI_TRUE" else: &"({t.c}){name}"
  of kEnum: &"({t.c}){name}"
  of kValue: &"genny_to_{t.c}(env, {name})"
  of kRef: &"(void *)(intptr_t){name}"
  of kBuffer: &"({name} == NULL ? NULL : (*env)->GetDirectBufferAddress(env, {name}))"
  else: name

proc cReturn(t: JType, expr: string): string =
  ## Converts the C value a Nim export returned to a JNI value.
  case t.kind
  of kString:
    # TODO: under ARC/ORC the char* from the internal export points into a
    # Nim string that is already freed when it returns. NewStringUTF must
    # copy it before anything else allocates; revisit with a threadvar holder.
    &"(*env)->NewStringUTF(env, {expr} == NULL ? \"\" : {expr})"
  of kPrim:
    if t.java == "boolean": &"({expr} ? JNI_TRUE : JNI_FALSE)" else: &"({t.jni}){expr}"
  of kEnum: &"(jint){expr}"
  of kValue: &"genny_from_{t.c}(env, {expr})"
  of kRef: &"(jlong)(intptr_t){expr}"
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
  let
    nativeName = "n_" & apiName.replace("$lib_", "")
    wrapperName = "genny_jni_" & apiName.replace("$lib_", "")

  var javaParams, cProtoParams, jniParams, sig, callArgs: seq[string]
  var setup, cleanup: string
  for i, (name, t) in params:
    let pname = &"p{i}"
    javaParams.add &"{t.native} {pname}"
    cProtoParams.add &"{t.c} {name}"
    jniParams.add &"{t.jni} {pname}"
    sig.add t.sig
    callArgs.add cArg(t, pname, setup, cleanup)

  libMembers.add &"  static native {ret.native} {nativeName}({javaParams.join(\", \")});\n"
  cProtos.add &"extern {ret.c} {apiName}({cProtoParams.join(\", \")});\n"

  var allJniParams = @["JNIEnv *env", "jclass cls"]
  allJniParams.add jniParams
  cWrappers.add &"static {ret.jni} {wrapperName}({allJniParams.join(\", \")}) {{\n"
  cWrappers.add "  (void)env; (void)cls;\n"
  cWrappers.add setup
  let call = &"{apiName}({callArgs.join(\", \")})"
  if ret.kind == kVoid:
    cWrappers.add &"  {call};\n"
  else:
    cWrappers.add &"  {ret.c} genny_result = {call};\n"
  cWrappers.add cleanup
  if raises:
    needsErrorBridge = true
    cWrappers.add "  if ($lib_check_error()) {\n"
    cWrappers.add "    char *genny_error = $lib_take_error();\n"
    cWrappers.add "    (*env)->ThrowNew(env, genny_exception_class, genny_error == NULL ? \"error\" : genny_error);\n"
    cWrappers.add &"    {zeroReturn(ret)}\n"
    cWrappers.add "  }\n"
  if ret.kind != kVoid:
    cWrappers.add &"  return {cReturn(ret, \"genny_result\")};\n"
  cWrappers.add "}\n\n"

  cMethods.add &"  {{\"{nativeName}\", \"({sig.join(\"\")}){ret.sig}\", (void *){wrapperName}}},\n"
  nativeName

proc javaCall(nativeName: string, args: seq[string], ret: JType): string =
  let call = &"{libClass}.{nativeName}({args.join(\", \")})"
  if ret.kind == kVoid:
    &"    {call};\n"
  else:
    &"    return {nativeToJava(ret, call)};\n"

proc exportConstJava*(sym: NimNode) =
  let t = jtype(sym.getTypeInst())
  if t.kind notin {kPrim, kString}:
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
  libMembers.add &"  public static final {t.java} {toCapSnakeCase(sym.repr)} = {value};\n"

proc exportEnumJava*(sym: NimNode) =
  let
    name = sym.repr
    entries = sym.getImpl()[2][1 .. ^1]
  var values: seq[string]
  for entry in entries:
    values.add toCapSnakeCase(entry.repr)
  enumNames.incl name
  enumSizes[name] = if entries.len <= 256: 1 else: 2
  enumValues[name] = values
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

  let nativeName = emitNative(apiName, params, ret, sym.raises())

  let onType = owner != nil and params.len > 0
  var publicParams, args: seq[string]
  for i, (name, t) in params:
    if i == 0 and onType:
      args.add javaToNative(t, "this")
    else:
      let jname = toVarCase(toCamelCase(name))
      publicParams.add &"{t.java} {jname}"
      args.add javaToNative(t, jname)

  let
    className = if onType: owner.getName() else: libClass
    modifier = if onType: "public" else: "public static"
  var code = &"  {modifier} {ret.java} {sym.repr}({publicParams.join(\", \")}) {{\n"
  code.add javaCall(nativeName, args, ret)
  code.add "  }\n"
  addMember(className, code)

proc emitValueConversions(name: string, fields: seq[(string, NimNode)]) =
  ## C helpers between the Java value class and the Nim struct.
  cTypes.add &"typedef struct {name} {{\n"
  for (fieldName, fieldType) in fields:
    cTypes.add &"  {jtype(fieldType).c} {fieldName};\n"
  cTypes.add &"}} {name};\n\n"

  cHelpers.add &"static jclass genny_class_{name};\n"
  cHelpers.add &"static jmethodID genny_init_{name};\n"
  for (fieldName, _) in fields:
    cHelpers.add &"static jfieldID genny_field_{name}_{fieldName};\n"

  cHelpers.add &"static {name} genny_to_{name}(JNIEnv *env, jobject o) {{\n"
  cHelpers.add &"  {name} r;\n"
  cHelpers.add "  memset(&r, 0, sizeof(r));\n"
  cHelpers.add "  if (o == NULL) return r;\n"
  for (fieldName, fieldType) in fields:
    let
      t = jtype(fieldType)
      fid = &"genny_field_{name}_{fieldName}"
    case t.kind
    of kPrim:
      if t.java == "boolean":
        cHelpers.add &"  r.{fieldName} = (*env)->GetBooleanField(env, o, {fid}) == JNI_TRUE;\n"
      else:
        cHelpers.add &"  r.{fieldName} = ({t.c})(*env)->Get{t.field}Field(env, o, {fid});\n"
    of kEnum:
      cHelpers.add &"  {{ jobject e = (*env)->GetObjectField(env, o, {fid});\n"
      cHelpers.add &"    r.{fieldName} = e == NULL ? 0 : ({t.c})(*env)->CallIntMethod(env, e, genny_enum_ordinal);\n"
      cHelpers.add "    if (e != NULL) (*env)->DeleteLocalRef(env, e); }\n"
    of kValue:
      cHelpers.add &"  {{ jobject v = (*env)->GetObjectField(env, o, {fid});\n"
      cHelpers.add &"    r.{fieldName} = genny_to_{t.c}(env, v);\n"
      cHelpers.add "    if (v != NULL) (*env)->DeleteLocalRef(env, v); }\n"
    else: discard
  cHelpers.add "  return r;\n}\n\n"

  var ctorSig, ctorArgs, setup, cleanup: string
  for (fieldName, fieldType) in fields:
    let t = jtype(fieldType)
    ctorSig.add t.publicSig
    case t.kind
    of kPrim:
      if t.java == "boolean":
        ctorArgs.add &", (jboolean)(v.{fieldName} ? JNI_TRUE : JNI_FALSE)"
      else:
        ctorArgs.add &", ({t.jni})v.{fieldName}"
    of kEnum:
      setup.add &"  jobject f_{fieldName} = (*env)->CallStaticObjectMethod(env, genny_class_{t.java}, genny_from_ordinal_{t.java}, (jint)v.{fieldName});\n"
      cleanup.add &"  (*env)->DeleteLocalRef(env, f_{fieldName});\n"
      ctorArgs.add &", f_{fieldName}"
    of kValue:
      setup.add &"  jobject f_{fieldName} = genny_from_{t.c}(env, v.{fieldName});\n"
      cleanup.add &"  (*env)->DeleteLocalRef(env, f_{fieldName});\n"
      ctorArgs.add &", f_{fieldName}"
    else: discard
  cHelpers.add &"static jobject genny_from_{name}(JNIEnv *env, {name} v) {{\n"
  cHelpers.add setup
  cHelpers.add &"  jobject r = (*env)->NewObject(env, genny_class_{name}, genny_init_{name}{ctorArgs});\n"
  cHelpers.add cleanup
  cHelpers.add "  return r;\n}\n\n"

  cOnLoad.add &"  if (!genny_load_class(env, \"{classPath(name)}\", &genny_class_{name})) return JNI_ERR;\n"
  cOnLoad.add &"  genny_init_{name} = (*env)->GetMethodID(env, genny_class_{name}, \"<init>\", \"({ctorSig})V\");\n"
  cOnLoad.add &"  if (genny_init_{name} == NULL) return JNI_ERR;\n"
  for (fieldName, fieldType) in fields:
    let t = jtype(fieldType)
    cOnLoad.add &"  genny_field_{name}_{fieldName} = (*env)->GetFieldID(env, genny_class_{name}, \"{toVarCase(toCamelCase(fieldName))}\", \"{t.publicSig}\");\n"
    cOnLoad.add &"  if (genny_field_{name}_{fieldName} == NULL) return JNI_ERR;\n"

proc exportObjectJava*(sym: NimNode, constructor: NimNode) =
  let name = sym.repr
  var
    fields: seq[(string, NimNode)]
    supported = true
  for identDefs in sym.getImpl()[2][2]:
    for property in identDefs[0 .. ^3]:
      let t = jtype(identDefs[^2])
      if t.kind notin {kPrim, kEnum, kValue}:
        supported = false
      fields.add((toSnakeCase(property[1].repr), identDefs[^2]))
  if not supported:
    warning(&"genny java: skipping object {name}, only primitive, enum and object fields are supported", sym)
    return

  valueNames.incl name
  valueFields[name] = fields
  classKinds[name] = kValue
  emitValueConversions(name, fields)

  var code = ""
  var ctorParams, assigns, eqs, hashes: seq[string]
  for (fieldName, fieldType) in fields:
    let
      t = jtype(fieldType)
      jname = toVarCase(toCamelCase(fieldName))
    code.add &"  public {t.java} {jname};\n"
    ctorParams.add &"{t.java} {jname}"
    assigns.add &"    this.{jname} = {jname};\n"
    if t.kind == kPrim:
      eqs.add &"{jname} == o.{jname}"
    else:
      eqs.add &"java.util.Objects.equals({jname}, o.{jname})"
    hashes.add jname
  code.add &"\n  public {name}() {{}}\n\n"
  code.add &"  public {name}({ctorParams.join(\", \")}) {{\n"
  code.add assigns.join("")
  code.add "  }\n\n"
  code.add "  @Override public boolean equals(Object other) {\n"
  code.add &"    if (!(other instanceof {name})) return false;\n"
  code.add &"    {name} o = ({name})other;\n"
  code.add &"    return {eqs.join(\" && \")};\n"
  code.add "  }\n\n"
  code.add "  @Override public int hashCode() {\n"
  code.add &"    return java.util.Objects.hash({hashes.join(\", \")});\n"
  code.add "  }\n\n"
  addMember(name, code)

  if constructor != nil:
    let
      ctorType = constructor.getTypeInst()
      ret = jtype(sym)
    var params: seq[(string, JType)]
    for param in ctorType[0][1 .. ^1]:
      params.add((param[0].repr.split('`')[0], jtype(param[1])))
    let nativeName = emitNative(&"$lib_{toSnakeCase(name)}", params, ret, false)
    var publicParams, args: seq[string]
    for (pname, t) in params:
      let jname = toVarCase(toCamelCase(pname))
      publicParams.add &"{t.java} {jname}"
      args.add javaToNative(t, jname)
    var ctor = &"  public static {name} {constructor.repr}({publicParams.join(\", \")}) {{\n"
    ctor.add javaCall(nativeName, args, ret)
    ctor.add "  }\n\n"
    addMember(name, ctor)

proc emitHandleClass(name, unrefApi: string) =
  ## Members shared by ref objects and seqs: the handle, wrapping and
  ## releasing. The Cleaner releases on its own thread, and Nim refcounts are
  ## not atomic, so objects shared with other threads should be closed
  ## explicitly instead of left to the Cleaner.
  let unrefNative = emitNative(unrefApi, @[("x", JType(kind: kRef,
    native: "long", jni: "jlong", sig: "J", c: "void *"))],
    jtype(newEmptyNode()), false)
  var code = ""
  code.add "  final long handle;\n"
  code.add "  private final java.lang.ref.Cleaner.Cleanable cleanable;\n\n"
  code.add &"  private {name}(long handle, Void wrapped) {{\n"
  code.add "    this.handle = handle;\n"
  code.add &"    this.cleanable = {libClass}.CLEANER.register(this, new Release(handle));\n"
  code.add "  }\n\n"
  code.add &"  static {name} wrap(long handle) {{\n"
  code.add &"    return handle == 0L ? null : new {name}(handle, null);\n"
  code.add "  }\n\n"
  code.add "  private static final class Release implements Runnable {\n"
  code.add "    private final long handle;\n"
  code.add "    Release(long handle) { this.handle = handle; }\n"
  code.add &"    @Override public void run() {{ {libClass}.{unrefNative}(handle); }}\n"
  code.add "  }\n\n"
  code.add "  /** Releases the Nim object. Do not use this object afterwards. */\n"
  code.add "  @Override public void close() { cleanable.clean(); }\n\n"
  addMember(name, code)

proc emitSeqAccessors(className, prefix, methodPrefix: string, selfType, entry: JType) =
  ## len/get/set/add/delete/clear for a seq or a seq field.
  let
    index = jtype(ident"int")
    voidT = jtype(newEmptyNode())
    self = ("s", selfType)
  proc name(op: string): string =
    if methodPrefix == "": op else: methodPrefix & op.capitalizeAscii()
  var code = ""
  var n = emitNative(prefix & "_len", @[self], index, false)
  code.add &"  public long {name(\"len\")}() {{\n    return {libClass}.{n}(handle);\n  }}\n\n"
  n = emitNative(prefix & "_get", @[self, ("i", index)], entry, false)
  let getCall = nativeToJava(entry, libClass & "." & n & "(handle, i)")
  code.add &"  public {entry.java} {name(\"get\")}(long i) {{\n"
  code.add &"    return {getCall};\n  }}\n\n"
  n = emitNative(prefix & "_set", @[self, ("i", index), ("v", entry)], voidT, false)
  code.add &"  public void {name(\"set\")}(long i, {entry.java} v) {{\n"
  code.add &"    {libClass}.{n}(handle, i, {javaToNative(entry, \"v\")});\n  }}\n\n"
  n = emitNative(prefix & "_add", @[self, ("v", entry)], voidT, false)
  code.add &"  public void {name(\"add\")}({entry.java} v) {{\n"
  code.add &"    {libClass}.{n}(handle, {javaToNative(entry, \"v\")});\n  }}\n\n"
  n = emitNative(prefix & "_delete", @[self, ("i", index)], voidT, false)
  code.add &"  public void {name(\"delete\")}(long i) {{\n    {libClass}.{n}(handle, i);\n  }}\n\n"
  n = emitNative(prefix & "_clear", @[self], voidT, false)
  code.add &"  public void {name(\"clear\")}() {{\n    {libClass}.{n}(handle);\n  }}\n\n"
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
    if supported:
      let nativeName = emitNative(&"$lib_{toSnakeCase(constructor.repr)}",
        params, self, constructor.raises())
      var publicParams, args: seq[string]
      for (pname, t) in params:
        let jname = toVarCase(toCamelCase(pname))
        publicParams.add &"{t.java} {jname}"
        args.add javaToNative(t, jname)
      var code = &"  public {name}({publicParams.join(\", \")}) {{\n"
      code.add &"    this({libClass}.{nativeName}({args.join(\", \")}), null);\n"
      code.add "  }\n\n"
      addMember(name, code)
    else:
      warning(&"genny java: skipping constructor of {name}, unsupported types", sym)

  for (fieldName, fieldType) in fields:
    let fieldSnaked = toSnakeCase(fieldName)
    if fieldType.kind == nnkBracketExpr:
      let entry = jtype(fieldType[1])
      if entry.kind == kUnsupported or entry.kind == kString:
        warning(&"genny java: skipping field {name}.{fieldName}, unsupported seq entry type", sym)
        continue
      emitSeqAccessors(name, &"$lib_{snaked}_{fieldSnaked}", fieldName, self, entry)
      continue
    let t = jtype(fieldType)
    if t.kind == kUnsupported:
      warning(&"genny java: skipping field {name}.{fieldName}, unsupported type", sym)
      continue
    let
      getter = emitNative(&"$lib_{snaked}_get_{fieldSnaked}", @[("o", self)], t, false)
      setter = emitNative(&"$lib_{snaked}_set_{fieldSnaked}",
        @[("o", self), ("v", t)], jtype(newEmptyNode()), false)
      cap = fieldName.capitalizeAscii()
    var code = ""
    let getCall = nativeToJava(t, libClass & "." & getter & "(handle)")
    code.add &"  public {t.java} get{cap}() {{\n"
    code.add &"    return {getCall};\n  }}\n\n"
    code.add &"  public void set{cap}({t.java} v) {{\n"
    code.add &"    {libClass}.{setter}(handle, {javaToNative(t, \"v\")});\n  }}\n\n"
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
  let newNative = emitNative(&"$lib_new_{snaked}", @[], self, false)
  addMember(name, &"  public {name}() {{\n    this({libClass}.{newNative}(), null);\n  }}\n\n")
  if entry.kind == kUnsupported:
    warning(&"genny java: skipping accessors of {name}, unsupported entry type", sym)
    return
  emitSeqAccessors(name, &"$lib_{snaked}", "", self, entry)

proc writeJava*(dir, lib: string): NimNode =
  let
    className = javaClassName(lib)
    javaDir = dir / "java" / gennyJavaPackage.replace('.', '/')
    cPath = dir / (toSnakeCase(lib) & "_jni.c")
    javaHome = getEnv("JAVA_HOME")
    exceptionClass = className & "Exception"

  if javaHome == "":
    error("genny java: JAVA_HOME must be set to a JDK so jni.h can be found")

  createDir(javaDir)

  proc header(): string =
    &"package {gennyJavaPackage};\n\n"

  var java = header()
  java.add &"public final class {className} {{\n"
  java.add &"  private {className}() {{}}\n\n"
  java.add "  static final java.lang.ref.Cleaner CLEANER = java.lang.ref.Cleaner.create();\n\n"
  java.add "  /** Loads the native library from an absolute path. */\n"
  java.add "  public static void load(String absolutePath) {\n"
  java.add "    System.load(absolutePath);\n"
  java.add "  }\n\n"
  java.add libMembers
  java.add "}\n"
  writeFile(javaDir / (className & ".java"), java.replace(libClass, className))

  var exc = header()
  exc.add &"public class {exceptionClass} extends RuntimeException {{\n"
  exc.add &"  public {exceptionClass}(String message) {{ super(message); }}\n"
  exc.add "}\n"
  writeFile(javaDir / (exceptionClass & ".java"), exc)

  for name, values in enumValues:
    var code = header()
    code.add &"public enum {name} {{\n"
    code.add "  " & values.join(", ") & ";\n\n"
    code.add &"  private static final {name}[] VALUES = values();\n\n"
    code.add &"  static {name} fromOrdinal(int ordinal) {{ return VALUES[ordinal]; }}\n"
    code.add "}\n"
    writeFile(javaDir / (name & ".java"), code)

  for name, members in classMembers:
    var code = header()
    case classKinds.getOrDefault(name, kRef)
    of kValue:
      code.add &"public final class {name} {{\n"
    else:
      code.add &"public final class {name} implements AutoCloseable {{\n"
    code.add members
    code.add "}\n"
    writeFile(javaDir / (name & ".java"), code.replace(libClass, className))

  var code = ""
  code.add "#include <jni.h>\n"
  code.add "#include <stdbool.h>\n"
  code.add "#include <stdint.h>\n"
  code.add "#include <string.h>\n\n"
  code.add "extern void NimMain(void);\n\n"
  if needsErrorBridge:
    code.add "extern bool $lib_check_error(void);\n"
    code.add "extern char *$lib_take_error(void);\n"
  code.add "static jclass genny_exception_class;\n"
  code.add "static jmethodID genny_enum_ordinal;\n"
  for name in enumNames:
    code.add &"static jclass genny_class_{name};\n"
    code.add &"static jmethodID genny_from_ordinal_{name};\n"
  code.add "\n"
  code.add "static int genny_load_class(JNIEnv *env, const char *name, jclass *out) {\n"
  code.add "  jclass local = (*env)->FindClass(env, name);\n"
  code.add "  if (local == NULL) return 0;\n"
  code.add "  *out = (jclass)(*env)->NewGlobalRef(env, local);\n"
  code.add "  (*env)->DeleteLocalRef(env, local);\n"
  code.add "  return *out != NULL;\n"
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
  code.add "  (void)reserved;\n"
  code.add "  JNIEnv *env;\n"
  code.add "  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8) != JNI_OK) return JNI_ERR;\n"
  code.add "  NimMain();\n"
  code.add &"  if (!genny_load_class(env, \"{classPath(exceptionClass)}\", &genny_exception_class)) return JNI_ERR;\n"
  code.add "  {\n"
  code.add "    jclass enumClass = (*env)->FindClass(env, \"java/lang/Enum\");\n"
  code.add "    if (enumClass == NULL) return JNI_ERR;\n"
  code.add "    genny_enum_ordinal = (*env)->GetMethodID(env, enumClass, \"ordinal\", \"()I\");\n"
  code.add "    (*env)->DeleteLocalRef(env, enumClass);\n"
  code.add "  }\n"
  for name in enumNames:
    code.add &"  if (!genny_load_class(env, \"{classPath(name)}\", &genny_class_{name})) return JNI_ERR;\n"
    code.add &"  genny_from_ordinal_{name} = (*env)->GetStaticMethodID(env, genny_class_{name}, \"fromOrdinal\", \"(I)L{classPath(name)};\");\n"
    code.add &"  if (genny_from_ordinal_{name} == NULL) return JNI_ERR;\n"
  code.add cOnLoad
  code.add "  jclass cls;\n"
  code.add &"  if (!genny_load_class(env, \"{classPath(className)}\", &cls)) return JNI_ERR;\n"
  code.add "  jint count = (jint)(sizeof(genny_jni_methods) / sizeof(genny_jni_methods[0]));\n"
  code.add "  if ((*env)->RegisterNatives(env, cls, genny_jni_methods, count) != 0) return JNI_ERR;\n"
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
