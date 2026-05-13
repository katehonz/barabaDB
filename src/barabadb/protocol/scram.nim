## SCRAM-SHA-256 implementation per RFC 7677
## Provides: PBKDF2, HMAC-SHA-256, nonce generation, SCRAM message parsing

import std/strutils
import std/base64
import std/endians
import checksums/sha2

const
  DefaultIterationCount* = 4096
  NonceBytes = 24

type
  ScramCredential* = object
    salt*: string
    iterationCount*: int
    storedKey*: array[32, byte]
    serverKey*: array[32, byte]

  ScramServerState* = object
    username*: string
    clientFirstMessageBare*: string
    serverFirstMessage*: string
    authMessage*: string
    clientNonce*: string
    serverNonce*: string
    salt*: string
    iterationCount*: int
    storedKey*: array[32, byte]
    serverKey*: array[32, byte]

# ---------------------------------------------------------------------------
# Cryptographic primitives
# ---------------------------------------------------------------------------

proc hmacSha256*(key, message: string): array[32, byte] =
  ## HMAC-SHA-256 returning raw 32-byte digest.
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
  return cast[array[32, byte]](outerCtx.digest())

proc hmacSha256*(key: openArray[byte], message: string): array[32, byte] =
  let keyStr = newString(key.len)
  if key.len > 0:
    copyMem(addr keyStr[0], unsafeAddr key[0], key.len)
  return hmacSha256(keyStr, message)

proc hmacSha256*(key, message: openArray[byte]): array[32, byte] =
  let keyStr = newString(key.len)
  if key.len > 0:
    copyMem(addr keyStr[0], unsafeAddr key[0], key.len)
  let msgStr = newString(message.len)
  if message.len > 0:
    copyMem(addr msgStr[0], unsafeAddr message[0], message.len)
  return hmacSha256(keyStr, msgStr)

proc hmacSha256*(key: string, message: openArray[byte]): array[32, byte] =
  let msgStr = newString(message.len)
  if message.len > 0:
    copyMem(addr msgStr[0], unsafeAddr message[0], message.len)
  return hmacSha256(key, msgStr)

proc sha256*(data: string): array[32, byte] =
  var ctx = initSha_256()
  ctx.update(data.toOpenArray(0, data.len-1))
  return cast[array[32, byte]](ctx.digest())

proc sha256*(data: openArray[byte]): array[32, byte] =
  var s = newString(data.len)
  if data.len > 0:
    copyMem(addr s[0], unsafeAddr data[0], data.len)
  return sha256(s)

proc xorBytes*(a, b: openArray[byte]): seq[byte] =
  result = newSeq[byte](a.len)
  for i in 0..<a.len:
    result[i] = a[i] xor b[i]

proc pbkdf2HmacSha256*(password, salt: string, iterations: int): array[32, byte] =
  ## PBKDF2-HMAC-SHA-256 with 32-byte output length.
  var u: array[32, byte]
  var t: array[32, byte]

  # U_1 = HMAC(password, salt || BE32(1))
  var msg = salt
  var counterVal = 1'u32
  var counter: array[4, byte]
  bigEndian32(addr counter, unsafeAddr counterVal)
  var counterStr = newString(4)
  copyMem(addr counterStr[0], addr counter[0], 4)
  msg.add(counterStr)
  u = hmacSha256(password, msg)

  for i in 0..<32:
    t[i] = u[i]

  for i in 2..iterations:
    u = hmacSha256(password, u)
    for j in 0..<32:
      t[j] = t[j] xor u[j]

  return t

# ---------------------------------------------------------------------------
# Random & encoding helpers
# ---------------------------------------------------------------------------

proc generateNonce*(): string =
  ## Generate a cryptographically secure random nonce (base64-encoded).
  when defined(linux) or defined(macosx) or defined(bsd):
    let f = open("/dev/urandom")
    defer: f.close()
    var bytes = newString(NonceBytes)
    let readLen = f.readBuffer(addr bytes[0], NonceBytes)
    if readLen < NonceBytes:
      raise newException(IOError, "Failed to read enough random bytes")
    result = encode(bytes)
    # Strip padding for GS2 / SCRAM compatibility
    while result.endsWith("="):
      result.setLen(result.len - 1)
    result = result.replace("+", "-").replace("/", "_")
  else:
    # Fallback — NOT cryptographically secure, should not be used in production
    raise newException(IOError, "Secure random not available on this platform")

proc generateSalt*(): string =
  ## Generate a random salt (raw bytes).
  when defined(linux) or defined(macosx) or defined(bsd):
    let f = open("/dev/urandom")
    defer: f.close()
    result = newString(NonceBytes)
    let readLen = f.readBuffer(addr result[0], NonceBytes)
    if readLen < NonceBytes:
      raise newException(IOError, "Failed to read enough random bytes")
  else:
    raise newException(IOError, "Secure random not available on this platform")

proc toHex*(data: openArray[byte]): string =
  const hexChars = "0123456789abcdef"
  result = newString(data.len * 2)
  for i, b in data:
    result[i * 2] = hexChars[int(b shr 4)]
    result[i * 2 + 1] = hexChars[int(b and 0x0f)]

# ---------------------------------------------------------------------------
# SCRAM credential generation
# ---------------------------------------------------------------------------

proc createScramCredential*(password: string, salt: string = "",
                            iterationCount: int = DefaultIterationCount): ScramCredential =
  let actualSalt = if salt.len > 0: salt else: generateSalt()
  let saltedPassword = pbkdf2HmacSha256(password, actualSalt, iterationCount)
  let clientKey = hmacSha256(saltedPassword, "Client Key")
  let storedKey = sha256(clientKey)
  let serverKey = hmacSha256(saltedPassword, "Server Key")
  ScramCredential(
    salt: actualSalt,
    iterationCount: iterationCount,
    storedKey: storedKey,
    serverKey: serverKey,
  )

# ---------------------------------------------------------------------------
# SCRAM message parsing / building
# ---------------------------------------------------------------------------

proc parseClientFirst*(msg: string): (string, string, string) =
  ## Parse client-first-message: gs2-header,username,nonce
  ## Returns: (gs2_header, username, nonce)
  var parts = msg.split(",")
  if parts.len < 3:
    raise newException(ValueError, "Invalid client-first-message")
  var gs2 = parts[0]
  var username = ""
  var nonce = ""
  for i in 1..<parts.len:
    let p = parts[i]
    if p.startsWith("n="):
      username = p[2..^1]
    elif p.startsWith("r="):
      nonce = p[2..^1]
  if username.len == 0 or nonce.len == 0:
    raise newException(ValueError, "Missing username or nonce in client-first-message")
  return (gs2, username, nonce)

proc parseClientFinal*(msg: string): (string, string, seq[byte]) =
  ## Parse client-final-message: channel-binding,nonce,proof
  ## Returns: (channel_binding, nonce, proof_bytes)
  var cbind = ""
  var nonce = ""
  var proofHex = ""
  for p in msg.split(","):
    if p.startsWith("c="):
      cbind = p[2..^1]
    elif p.startsWith("r="):
      nonce = p[2..^1]
    elif p.startsWith("p="):
      proofHex = p[2..^1]
  if nonce.len == 0 or proofHex.len == 0:
    raise newException(ValueError, "Missing nonce or proof in client-final-message")
  # proof is base64-encoded
  var proof = decode(proofHex)
  var proofBytes = newSeq[byte](proof.len)
  if proof.len > 0:
    copyMem(addr proofBytes[0], addr proof[0], proof.len)
  return (cbind, nonce, proofBytes)

proc buildServerFirst*(nonce, salt: string, iterationCount: int): string =
  "r=" & nonce & ",s=" & encode(salt) & ",i=" & $iterationCount

proc buildServerFinal*(serverSignature: openArray[byte]): string =
  var sigStr = newString(serverSignature.len)
  if serverSignature.len > 0:
    copyMem(addr sigStr[0], unsafeAddr serverSignature[0], serverSignature.len)
  "v=" & encode(sigStr)

# ---------------------------------------------------------------------------
# SCRAM server-side verification
# ---------------------------------------------------------------------------

proc verifyClientProof*(state: ScramServerState, clientProof: openArray[byte]): bool =
  let clientKey = xorBytes(clientProof, @(hmacSha256(state.storedKey, state.authMessage)))
  let computedStoredKey = sha256(clientKey)
  for i in 0..<32:
    if computedStoredKey[i] != state.storedKey[i]:
      return false
  return true

proc computeServerSignature*(state: ScramServerState): array[32, byte] =
  return hmacSha256(state.serverKey, state.authMessage)
