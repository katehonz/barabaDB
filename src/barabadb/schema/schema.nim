## Schema System — SDL parser, types, links, migrations
import std/tables
import std/strutils
import std/sequtils
import std/sets

type
  SchemaModule* = ref object
    name*: string
    types*: Table[string, SchemaType]
    functions*: Table[string, SchemaFunction]
    globals*: Table[string, SchemaGlobal]

  SchemaType* = ref object
    name*: string
    module*: string
    bases*: seq[string]
    properties*: Table[string, SchemaProperty]
    links*: Table[string, SchemaLink]
    constraints*: seq[SchemaConstraint]
    indexes*: seq[SchemaIndex]
    isAbstract*: bool
    isFinal*: bool

  SchemaProperty* = object
    name*: string
    typeName*: string
    required*: bool
    multi*: bool
    default*: string
    computed*: bool
    expr*: string
    readonly*: bool

  SchemaLink* = object
    name*: string
    target*: string
    required*: bool
    multi*: bool
    properties*: Table[string, SchemaProperty]
    onDelete*: string

  SchemaConstraint* = object
    name*: string
    expr*: string
    args*: seq[string]

  SchemaIndex* = object
    name*: string
    expr*: string
    kind*: string

  SchemaFunction* = object
    name*: string
    params*: seq[SchemaParam]
    returnType*: string
    body*: string
    language*: string
    volatility*: string

  SchemaParam* = object
    name*: string
    typeName*: string
    required*: bool
    default*: string

  SchemaGlobal* = object
    name*: string
    typeName*: string
    required*: bool
    default*: string
    computed*: bool
    expr*: string

  Schema* = ref object
    modules*: Table[string, SchemaModule]
    version*: int
    migrations*: seq[Migration]

  Migration* = object
    id*: int
    message*: string
    script*: string
    timestamp*: int64
    parentId*: int

  SchemaDiff* = object
    addedTypes*: seq[string]
    removedTypes*: seq[string]
    modifiedTypes*: seq[TypeDiff]
    addedFunctions*: seq[string]
    removedFunctions*: seq[string]

  TypeDiff* = object
    name*: string
    addedProperties*: seq[string]
    removedProperties*: seq[string]
    modifiedProperties*: seq[PropertyDiff]
    addedLinks*: seq[string]
    removedLinks*: seq[string]

  PropertyDiff* = object
    name*: string
    oldType*: string
    newType*: string
    oldRequired*: bool
    newRequired*: bool

proc newSchema*(): Schema =
  Schema(
    modules: initTable[string, SchemaModule](),
    version: 0,
    migrations: @[],
  )

proc newModule*(name: string): SchemaModule =
  SchemaModule(
    name: name,
    types: initTable[string, SchemaType](),
    functions: initTable[string, SchemaFunction](),
    globals: initTable[string, SchemaGlobal](),
  )

proc newType*(name: string, module: string = "default"): SchemaType =
  SchemaType(
    name: name,
    module: module,
    bases: @[],
    properties: initTable[string, SchemaProperty](),
    links: initTable[string, SchemaLink](),
    constraints: @[],
    indexes: @[],
    isAbstract: false,
    isFinal: false,
  )

proc addProperty*(t: SchemaType, name: string, typeName: string,
                  required: bool = false, multi: bool = false,
                  default: string = "") =
  t.properties[name] = SchemaProperty(
    name: name,
    typeName: typeName,
    required: required,
    multi: multi,
    default: default,
  )

proc addLink*(t: SchemaType, name: string, target: string,
              required: bool = false, multi: bool = false) =
  t.links[name] = SchemaLink(
    name: name,
    target: target,
    required: required,
    multi: multi,
    properties: initTable[string, SchemaProperty](),
    onDelete: "RESTRICT",
  )

proc addConstraint*(t: SchemaType, name: string, expr: string) =
  t.constraints.add(SchemaConstraint(name: name, expr: expr))

proc addIndex*(t: SchemaType, name: string, expr: string, kind: string = "btree") =
  t.indexes.add(SchemaIndex(name: name, expr: expr, kind: kind))

proc addType*(s: Schema, module: string, t: SchemaType) =
  if module notin s.modules:
    s.modules[module] = newModule(module)
  s.modules[module].types[t.name] = t

proc getType*(s: Schema, name: string): SchemaType =
  for moduleName, module in s.modules:
    if name in module.types:
      return module.types[name]
  return nil

proc getAllTypes*(s: Schema): seq[SchemaType] =
  result = @[]
  for moduleName, module in s.modules:
    for typeName, t in module.types:
      result.add(t)

proc diff*(oldSchema, newSchema: Schema): SchemaDiff =
  var diff = SchemaDiff()

  let oldTypes = oldSchema.getAllTypes().mapIt(it.name).toHashSet()
  let newTypes = newSchema.getAllTypes().mapIt(it.name).toHashSet()

  for t in newTypes:
    if t notin oldTypes:
      diff.addedTypes.add(t)
  for t in oldTypes:
    if t notin newTypes:
      diff.removedTypes.add(t)

  for tname in newTypes:
    if tname in oldTypes:
      let oldT = oldSchema.getType(tname)
      let newT = newSchema.getType(tname)
      var td = TypeDiff(name: tname)

      for pname in newT.properties.keys:
        if pname notin oldT.properties:
          td.addedProperties.add(pname)
      for pname in oldT.properties.keys:
        if pname notin newT.properties:
          td.removedProperties.add(pname)

      for lname in newT.links.keys:
        if lname notin oldT.links:
          td.addedLinks.add(lname)
      for lname in oldT.links.keys:
        if lname notin newT.links:
          td.removedLinks.add(lname)

      if td.addedProperties.len > 0 or td.removedProperties.len > 0 or
         td.addedLinks.len > 0 or td.removedLinks.len > 0:
        diff.modifiedTypes.add(td)

  return diff

proc createMigration*(s: Schema, message: string, script: string): Migration =
  inc s.version
  let migration = Migration(
    id: s.version,
    message: message,
    script: script,
    timestamp: 0,
    parentId: if s.migrations.len > 0: s.migrations[^1].id else: 0,
  )
  s.migrations.add(migration)
  return migration

proc validateType*(t: SchemaType): seq[string] =
  result = @[]
  if t.name.len == 0:
    result.add("Type name cannot be empty")
  for pname, prop in t.properties:
    if prop.required and prop.default.len > 0 and prop.default == "{}":
      result.add("Property '" & pname & "' is required but has no default")
  for lname, link in t.links:
    if link.target.len == 0:
      result.add("Link '" & lname & "' has no target type")

proc validateSchema*(s: Schema): seq[string] =
  result = @[]
  for moduleName, module in s.modules:
    for typeName, t in module.types:
      result.add(t.validateType())
      for base in t.bases:
        if s.getType(base) == nil:
          result.add("Type '" & typeName & "' references unknown base '" & base & "'")
      for lname, link in t.links:
        if s.getType(link.target) == nil:
          result.add("Link '" & lname & "' in type '" & typeName &
                     "' references unknown target '" & link.target & "'")

proc `$`*(t: SchemaType): string =
  result = "type " & t.name
  if t.bases.len > 0:
    result &= " extending " & t.bases.join(", ")
  result &= " {\n"
  for pname, prop in t.properties:
    result &= "  "
    if prop.required:
      result &= "required "
    if prop.multi:
      result &= "multi "
    result &= pname & ": " & prop.typeName
    if prop.default.len > 0:
      result &= " default " & prop.default
    result &= ";\n"
  for lname, link in t.links:
    result &= "  "
    if link.required:
      result &= "required "
    if link.multi:
      result &= "multi "
    result &= "link " & lname & " -> " & link.target
    result &= ";\n"
  result &= "}\n"

proc `$`*(s: Schema): string =
  result = ""
  for moduleName, module in s.modules:
    for typeName, t in module.types:
      result &= $t & "\n"
