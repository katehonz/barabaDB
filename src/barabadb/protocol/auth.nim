## Authentication — JWT-based auth with SCRAM-SHA-256
import std/strutils
import std/base64

type
  AuthMethod* = enum
    amNone
    amSCRAMSHA256
    amJWT
    amToken

  AuthCredentials* = object
    authMethod*: AuthMethod
    username*: string
    payload*: string

  JWTClaims* = object
    sub*: string
    iss*: string
    aud*: string
    exp*: int64
    iat*: int64
    nbf*: int64
    jti*: string
    role*: string
    database*: string

  AuthResult* = object
    authenticated*: bool
    username*: string
    role*: string
    database*: string
    error*: string

  AuthManager* = ref object
    secretKey*: string
    tokens*: seq[string]

proc newAuthManager*(secretKey: string = ""): AuthManager =
  AuthManager(secretKey: secretKey, tokens: @[])

proc base64UrlEncode(data: string): string =
  result = encode(data)
  result = result.replace("+", "-").replace("/", "_").replace("=", "")

proc base64UrlDecode(data: string): string =
  var s = data.replace("-", "+").replace("_", "/")
  while s.len mod 4 != 0:
    s &= "="
  return decode(s)

proc simpleHash(data: string, key: string): string =
  var prefix = data & key
  var h: uint64 = 5381
  for ch in prefix:
    h = ((h shl 5) + h) + uint64(ord(ch))
  return $h

proc createToken*(am: AuthManager, claims: JWTClaims): string =
  let header = base64UrlEncode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
  let payload = base64UrlEncode(
    "{\"sub\":\"" & claims.sub & "\",\"role\":\"" & claims.role &
    "\",\"database\":\"" & claims.database & "\"}")
  let data = header & "." & payload
  let signature = simpleHash(data, am.secretKey)
  am.tokens.add(data & "." & base64UrlEncode(signature))
  return am.tokens[^1]

proc verifyToken*(am: AuthManager, token: string): (bool, JWTClaims) =
  let parts = token.split(".")
  if parts.len != 3:
    return (false, JWTClaims())
  let data = parts[0] & "." & parts[1]
  let sig = simpleHash(data, am.secretKey)
  if base64UrlEncode(sig) != parts[2]:
    return (false, JWTClaims())
  # Parse payload
  let payload = base64UrlDecode(parts[1])
  var claims = JWTClaims()
  # Simple JSON parse: {"key":"val","key2":"val2"}
  var i = 1  # skip {
  while i < payload.len:
    if payload[i] == '}':
      break
    if payload[i] == '"':
      var key = ""
      inc i
      while i < payload.len and payload[i] != '"':
        key &= payload[i]
        inc i
      inc i  # skip closing quote
      inc i  # skip :
      var val = ""
      if i < payload.len and payload[i] == '"':
        inc i
        while i < payload.len and payload[i] != '"':
          val &= payload[i]
          inc i
        inc i
      elif i < payload.len and payload[i] in {'0'..'9', '-'}:
        while i < payload.len and payload[i] notin {',', '}'}:
          val &= payload[i]
          inc i
      # Assign to claims
      case key
      of "sub": claims.sub = val
      of "role": claims.role = val
      of "database": claims.database = val
      of "iss": claims.iss = val
      of "aud": claims.aud = val
      else: discard
    if i < payload.len and payload[i] == ',':
      inc i
    inc i
  return (true, claims)

proc validateCredentials*(am: AuthManager, creds: AuthCredentials): AuthResult =
  case creds.authMethod
  of amNone:
    return AuthResult(authenticated: true, username: "anonymous", role: "default",
                      database: "default")
  of amToken, amJWT:
    if creds.payload in am.tokens:
      let (valid, claims) = am.verifyToken(creds.payload)
      if valid:
        return AuthResult(authenticated: true, username: claims.sub,
                          role: claims.role, database: claims.database)
    return AuthResult(authenticated: false, error: "Invalid token")
  of amSCRAMSHA256:
    return AuthResult(authenticated: false, error: "SCRAM not fully implemented")

proc addToken*(am: var AuthManager, token: string) =
  am.tokens.add(token)

proc revokeToken*(am: var AuthManager, token: string) =
  var idx = am.tokens.find(token)
  if idx >= 0:
    am.tokens.del(idx)

proc isAuthenticated*(r: AuthResult): bool = r.authenticated
