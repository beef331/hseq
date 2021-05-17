import std/[macros, macrocache, strutils, tables, decls, sugar]
export decls, sugar


const 
  typeTable = CacheTable"HseqTypeTable"
  caseTable = CacheTable"HseqCaseTable"

{.experimental: "dynamicBindSym".} # Needed so we dont have to pass type in

proc extractTypes(n: NimNode): seq[NimNode] =
  case n.kind:
  of nnkTypeDef:
    if n[^1].kind == nnkInfix: # This is a typeclass
      result.add n[^1].extractTypes
    else: # Object, enum, or tuple
      result.add n[0]
  of nnkSym:
    let impl = n.getImpl
    if impl.kind == nnkNilLit:
      result.add n
    else:
      result.add impl.extractTypes
  of nnkInfix:
    for x in n:
      result.add x.extractTypes
  of nnkBracketExpr:
    result.add n
  of nnkIdent:
    let binded = n.bindSym() # bind a sym so we can look it up
    if binded.kind != nnkClosedSymChoice:
      let impl = binded.getImpl # Get impl so we can get typ
      case impl.kind
      of nnkNilLit:
        result.add n
      of nnkProcDef: discard
      else:
        result.add impl.extractTypes
  of nnkPar: # Anonymous tuple support
    result.add n
  else: discard

proc toCleanIdent(typ: NimNode): string = typ.repr.multiReplace(("[", ""), ("]",""))

proc generateEnumInfo(types: seq[NimNode], typeName: string): seq[NimNode]= 
  ## Takes a list of types converts them into enumNames and adds the caseStmt
  let cstmt = newStmtList()
  for typ in types:
    let enumVal = ident(typeName & typ.toCleanIdent)
    cstmt.add nnkOfBranch.newTree(typ, enumVal) # We store `of a, b` so we can check a after
    result.add enumVal
  caseTable[typeName] = cstmt

proc toValName(val: NimNode, nameSize: int): NimNode = ident(($val).toLowerAscii[nameSize..^1] & "Val")

proc genAdd(name, typD: NimNode, allowedTypes: seq[NimNode]): NimNode =
  let
    strName = $name
    theSeq = ident("hseq")
    toAdd = ident("toAdd")
    entryTyp = ident(strName & "entry")
    stmt = caseTable[strName]
    body = newStmtList()
  for i, x in stmt:
    let 
      typ = x[0]
      fieldName = x[1].toValName(strName.len)
      enm = x[1]
    body.add quote do:
      when type(`toAdd`) is `typ`:
        `theSeq`.add `entryTyp`(kind: `enm`, `fieldName`: `toAdd`)
    if i > 0:
      body[^1] = body[^1][0]
  body[0].add body[1..^1]
  body.del(1, body.len - 1)
  
  result = quote do:
    proc add(`theSeq`: var `name`, `toAdd`: `typD`) = 
      `body`

proc genInitProcs(name: NimNode, allowedTypes: seq[NimNode]): NimNode =
  let
    strName = $name
    entryTyp = ident(strName & "entry")
    procName = ident("init" & $entryTyp)
    assignProc = nnkAccQuoted.newTree(ident("{}="))
    stmt = caseTable[strName]
  result = newStmtList()
  for i, x in stmt:
    let 
      typ = x[0]
      fieldName = x[1].toValName(strName.len)
      enm = x[1]
    result.add quote do:
      proc `procName`(val: `typ`): `entryTyp` {.inline.} = 
        ## Allows easy creation of Entries
        `entryTyp`(kind: `enm`, `fieldName`: val)
      proc `assignProc`(hseq: var `name`, i: int, val: `typ`) {.inline.} = 
        ## Used to assign indicies directly as if it was a `seq[val.Type]`
        hseq[i] = `procName`(val)

macro makeHseq(name: untyped, types: typedesc): untyped =
  let
    strName = $name
    allowedTypes = types.extractTypes
    enumVals = allowedTypes.generateEnumInfo($name)
    enumName = ident($name & "Kind")
    elementName = ident($name & "Entry")
    kind = ident("kind")
  
  typeTable[strName] = types

  result = newStmtList()
  result.add newEnum(enumName, enumvals, false, true)
  let 
    entryType = quote do:
      type `elementName` = object
        case `kind`: `enumName`
    recList = entryType[^1][^1][^1][^1]
  for x in caseTable[strName]:
    let 
      val = x.copyNimTree
      typ = val[0]
    val.del(0, 1)
    val.add newIdentDefs(val[0].toValName(strName.len), typ, newEmptyNode())
    recList.add val
  result.add entryType
  result.add quote do:
    type `name` = seq[`elementName`]
  result.add genAdd(name, types, allowedTypes)
  result.add genInitProcs(name, allowedTypes)
  echo result.repr

proc parseCaseOf(body, value, seqType, alias: NimNode, mutable = false): NimNode =
  var 
    ops: Table[string, NimNode]
    elseOp = newEmptyNode()
  
  for x in body:
    if x.kind == nnkCommand and x[0].eqident("caseOf"):
      let types = x[1].extractTypes
      for typ in types:
        let typ = typ.toCleanIdent
        assert typ notin ops, "Duplicated case conditions"
        ops[typ] = x[2].copyNimTree()
      if x[^1].kind == nnkElse:
        elseOp = x[^1][0]

  let 
    caseStmt = nnkCaseStmt.newNimNode()
  caseStmt.add newDotExpr(value, ident("kind"))
  if ops.len > 0:
    for x in caseTable[$seqType]:
      let 
        typeName = x[0].toCleanIdent
        fieldName = x[1].toValName(($seqType).len)
      let itConstr =
        if mutable:
          let newAlias = nnkPragmaExpr.newTree(alias, nnkPragma.newTree(ident"byaddr"))
          newVarStmt(newAlias, newDotExpr(value, fieldName))
        else:
          newLetStmt(alias, newDotExpr(value, fieldName))
      if typeName in ops:
        let 
          newStmt = x.copyNimTree()
          bodyCopy = ops[typeName].copyNimTree
        bodyCopy.insert 0, itConstr
        newStmt.add bodyCopy
        newStmt.del(0, 1)
        caseStmt.add newStmt
      elif elseOp.kind != nnkEmpty:
        let 
          newStmt = x.copyNimTree()
          bodyCopy = elseOp.copyNimTree
        bodyCopy.insert 0, itConstr
        newStmt.add bodyCopy
        newStmt.del(0, 1)
        caseStmt.add newStmt

    if elseOp.kind == nnkEmpty:
      let discardStmt = nnkElse.newTree(nnkStmtList.newTree(nnkDiscardStmt.newTree(newEmptyNode())))
      caseStmt.add discardStmt
  else:
    for x in caseTable[$seqType]:
      let 
        fieldName = x[1].toValName(($seqType).len)
        itConstr = 
          if mutable:
            let newAlias = nnkPragmaExpr.newTree(alias, nnkPragma.newTree(ident"byaddr"))
            newVarStmt(newAlias, newDotExpr(value, fieldName))
          else:
            newLetStmt(alias, newDotExpr(value, fieldName))
        newStmt = x.copyNimTree()
        bodyCopy = body.copyNimTree()
      bodyCopy.insert 0, itConstr
      newStmt.add bodyCopy
      newStmt.del(0, 1)
      caseStmt.add newStmt
  result = nnkStmtList.newTree(caseStmt)

proc hseqIterImpl(body: NimNode, mutable = false): NimNode =
  let
    alias = body[0]
    seqName = body[1][1]
    body = body[^1]
    seqType = bindSym(seqName).getImpl[1]
    iName = gensym(nskVar, "i")
    indexed = nnkBracketExpr.newTree(seqName, iName)
    caseStmt = parseCaseOf(body, indexed, seqType, alias, mutable)
  
  result = quote do:
    var `iName` = 0
    while `iName` < `seqName`.len:
      block:
        `caseStmt`
      inc `iName`

macro withIndex*(hSeq: typed, index: int, body: untyped): untyped =
  ## Can index the `hSeq` with an int then operate on the bodys
  ## Using an additive body so `caseof SomeInteger` + `caseof int`'s bodies
  let 
    typ = hSeq.getImpl[1]
    indexed = nnkBracketExpr.newTree(hSeq, index)
  result = parseCaseOf(body, indexed, typ, ident("it"), true)

macro pop*(hseq: typed, body: untyped): untyped =
  ## Pops the top object of the object and can operate on it
  let 
    typ = hseq.getImpl[1]
    valueId = gensym(nskVar, "Val")
  result = nnkStmtList.newTree quote do:
    var `valueId` = `hSeq`.pop
  result.add parseCaseOf(body, valueId, typ, ident("it"), true)

proc getFieldEnumName(seqType, val: NimNode): (NimNode, NimNode) =
  ## Give a type and a val iterate through the casestmt to extract,
  ## enum value and field name
  for x in caseTable[$seqType]:
    if x[0].eqIdent(val):
      result[0] = x[1].toValName(($seqType).len)
      result[1] = x[1]
      break

macro find*(hseq: typed, val: typedesc): untyped =
  ## Iterates the `hseq` returning all variants of the given type
  let seqType = hseq.getImpl[1]
  var (fieldName, enumName) = getFieldEnumName(seqType, val)
  assert nnkEmpty notin {fieldName.kind, enumName.kind}, "Cannot filter a type not in the variant"
  result = quote do:
    block:
      var res = newSeq[`val`]()
      for val in `hseq`:
        if val.kind == `enumName`:
          res.add(val.`fieldName`)
      res

macro filter*(hseq: typed, val: typedesc): untyped =
  ## Iterates the `hseq` removing all variants that map to that type
  let seqType = hseq.getImpl[1]
  var (fieldName, enumName) = getFieldEnumName(seqType, val)
  assert nnkEmpty notin {fieldName.kind, enumName.kind}, "Cannot filter a type not in the variant"
  result = quote do:
    var i = `hSeq`.high
    while i > 0:
      if `hseq`[i].kind == `enumName`:
        `hSeq`.delete(i)
      dec i

macro hSeqItems*(a: ForLoopStmt): untyped =
  hseqIterImpl(a)

macro hSeqMitems*(a: ForLoopStmt): untyped =
  hseqIterImpl(a, true)

when isMainModule:
  type 
    TestType = object
    AcceptedTypes = int or float

  makeHseq(Test, AcceptedTypes)

  var a: Test
  a.add(300)
  a.add(0.5)

  a.withIndex(1):
    caseof int:
      echo it * 3
    else:
      echo it * 2

  for it in hSeqItems(a):
    echo it

  echo "\n\nMutate! \n\n "

  for it in hSeqMitems(a):
    caseof int:
      it = 40

  # Remove the float
  a.pop():
    echo "Buh buy ", it

  for it in hSeqItems(a):
    echo it
  a.add(300)
  a.add(400)
  a.add(0.5)
  echo a.find(int)
  echo a.find(float)
  a.filter(float)
  for it in hSeqItems(a):
    echo it
  a{0} = 10.0
  for it in hseqItems(a):
    echo it
