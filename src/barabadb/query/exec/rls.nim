## Row-Level Security — privilege checks and policy evaluation.
##
## Extracted from `executor.nim` (Task 7 of the executor split).
import std/tables
import types
import values
import eval
import lower

# ----------------------------------------------------------------------
# Row-Level Security
# ----------------------------------------------------------------------

proc hasPrivilege*(ctx: ExecutionContext, tableName, command: string): bool =
  if ctx.currentUser.len == 0: return true
  let user = ctx.users.getOrDefault(ctx.currentUser)
  if user.isSuperuser: return true
  # Check table-level policies for user or PUBLIC
  # For now: if no policies exist, allow everything (backward compatible)
  if tableName notin ctx.policies: return true
  let policies = ctx.policies[tableName]
  # If RLS is enabled (policies exist), check if user matches any policy
  for pol in policies:
    if pol.command == "ALL" or pol.command == command:
      return true
  return false

proc passesPolicy*(ctx: ExecutionContext, tableName, command: string, row: Row): bool =
  if ctx.currentUser.len == 0: return true
  let user = ctx.users.getOrDefault(ctx.currentUser)
  if user.isSuperuser: return true
  if tableName notin ctx.policies: return true
  let policies = ctx.policies[tableName]
  for pol in policies:
    if pol.command != "ALL" and pol.command != command:
      continue
    if pol.usingExpr != nil:
      let expr = lowerExpr(pol.usingExpr)
      if valueToString(evalExpr(expr, row, ctx)) != "true":
        return false
  return true

proc checkInsertPolicy*(ctx: ExecutionContext, tableName: string, row: Row): bool =
  if ctx.currentUser.len == 0: return true
  let user = ctx.users.getOrDefault(ctx.currentUser)
  if user.isSuperuser: return true
  if tableName notin ctx.policies: return true
  let policies = ctx.policies[tableName]
  for pol in policies:
    if pol.command != "ALL" and pol.command != "INSERT":
      continue
    if pol.withCheckExpr != nil:
      let expr = lowerExpr(pol.withCheckExpr)
      if valueToString(evalExpr(expr, row, ctx)) != "true":
        return false
  return true
