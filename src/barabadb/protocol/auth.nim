## Authentication — JWT-based auth with SCRAM-SHA-256
import std/strutils
import std/base64
import std/tables
import std/times
import checksums/sha2

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
    users*: Table[string, string]  # username -> password hash

proc newAuthManager*(secretKey: string = ""): AuthManager =
  AuthManager(secretKey: secretKey, tokens: @[], users: initTable[string, string]())

proc base64UrlEncode(data: string): string =
  result = encode(data)
  result = result.replace("+", "-").replace("/", "_").replace("=", "")

proc base64UrlDecode(data: string): string =
  var s = data.replace("-", "+").replace("_", "/")
  while s.len mod 4 != 0:
    s &= "="
  return decode(s)

proc hmacSha256(key, message: string): string =
  var k = key
  if k.len > 64:
    var ctx = initSha_256()
    ctx.update(k.toOpenArray(0, k.len-1))
    let hash = ctx.digest()
    k = $hash
  while k.len < 64:
    k &= "\x00"

  var ipad = newString(64)
  var opad = newString(64)
  for i in 0..<64:
    ipad[i] = chr(ord(k[i]) xor 0x36)
    opad[i] = chr(ord(k[i]) xor 0x5c)

  var innerCtx = initSha_256()
  innerCtx.update(ipad.toOpenArray(0, ipad.len-1))
  innerCtx.update(message.toOpenArray(0, message.len-1))
  let innerHash = innerCtx.digest()

  var outerCtx = initSha_256()
  outerCtx.update(opad.toOpenArray(0, opad.len-1))
  outerCtx.update(innerHash.toOpenArray(0, innerHash.len-1))
  let outerHash = outerCtx.digest()

  return $outerHash

proc createToken*(am: AuthManager, claims: JWTClaims): string =
  let header = base64UrlEncode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
  var payloadJson = "{\"sub\":\"" & claims.sub & "\",\"role\":\"" & claims.role &
    "\",\"database\":\"" & claims.database & "\""
  if claims.exp > 0:
    payloadJson &= ",\"exp\":" & $claims.exp
  if claims.iat > 0:
    payloadJson &= ",\"iat\":" & $claims.iat
  if claims.nbf > 0:
    payloadJson &= ",\"nbf\":" & $claims.nbf
  payloadJson &= "}"
  let payload = base64UrlEncode(payloadJson)
  let data = header & "." & payload
  let signature = hmacSha256(am.secretKey, data)
  am.tokens.add(data & "." & base64UrlEncode(signature))
  return am.tokens[^1]

proc constantTimeCompare(a, b: string): bool =
  if a.len != b.len:
    return false
  var result = 0
  for i in 0..<a.len:
    result = result or (ord(a[i]) xor ord(b[i]))
  return result == 0

proc verifyToken*(am: AuthManager, token: string): (bool, JWTClaims) =
  let parts = token.split(".")
  if parts.len != 3:
    return (false, JWTClaims())
  let data = parts[0] & "." & parts[1]
  let sig = hmacSha256(am.secretKey, data)
  if not constantTimeCompare(base64UrlEncode(sig), parts[2]):
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
      of "exp": claims.exp = parseInt(val)
      of "iat": claims.iat = parseInt(val)
      of "nbf": claims.nbf = parseInt(val)
      of "jti": claims.jti = val
      else: discard
    if i < payload.len and payload[i] == ',':
      inc i
    inc i
  # Validate expiration
  let now = int64(getTime().toUnix())
  if claims.exp > 0 and now > claims.exp:
    return (false, JWTClaims())
  if claims.nbf > 0 and now < claims.nbf:
    return (false, JWTClaims())
  if claims.iat > 0 and now < claims.iat - 60:
    # Allow 60 seconds clock skew
    return (false, JWTClaims())
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
    if creds.username in am.users:
      let stored = am.users[creds.username]
      # SCRAM-SHA-256: client sends SHA-256(password) as payload
      let clientHash = if creds.payload.len > 0: creds.payload else: hmacSha256(am.secretKey, "")
      if stored == clientHash or stored == hmacSha256(am.secretKey, creds.payload):
        return AuthResult(authenticated: true, username: creds.username,
                          role: "user", database: "default")
    return AuthResult(authenticated: false, error: "Invalid SCRAM credentials")

proc addToken*(am: var AuthManager, token: string) =
  am.tokens.add(token)

proc revokeToken*(am: var AuthManager, token: string) =
  var idx = am.tokens.find(token)
  if idx >= 0:
    am.tokens.del(idx)

proc isAuthenticated*(r: AuthResult): bool = r.authenticated

proc addScramUser*(am: var AuthManager, username, passwordHash: string) =
  am.users[username] = passwordHash
