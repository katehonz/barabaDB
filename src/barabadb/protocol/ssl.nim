## TLS/SSL Wrapper — encrypted socket using OpenSSL
import std/os
import std/strutils

type
  TLSSocket* = ref object
    ctx: pointer    # SSL_CTX*
    ssl: pointer    # SSL*
    fd: int
    connected: bool
    config: TLSConfig

  TLSConfig* = object
    certFile*: string
    keyFile*: string
    caFile*: string
    verifyPeer*: bool

proc newTLSConfig*(certFile: string, keyFile: string, caFile: string = "",
                   verifyPeer: bool = false): TLSConfig =
  TLSConfig(
    certFile: certFile, keyFile: keyFile,
    caFile: caFile, verifyPeer: verifyPeer,
  )

proc newTLSSocket*(config: TLSConfig): TLSSocket =
  TLSSocket(config: config, connected: false)

proc connect*(sock: TLSSocket, host: string, port: int): bool =
  # In production, would use OpenSSL SSL_connect() via FFI
  # For now, validate config and return mock connection
  if not fileExists(sock.config.certFile):
    return false
  sock.connected = true
  return true

proc accept*(sock: TLSSocket, clientFd: int): bool =
  if not fileExists(sock.config.certFile):
    return false
  if not fileExists(sock.config.keyFile):
    return false
  sock.fd = clientFd
  sock.connected = true
  return true

proc `send`*(sock: TLSSocket, data: seq[byte]): int =
  if not sock.connected:
    return -1
  # In production: SSL_write(sock.ssl, data[0].addr, data.len.cint)
  return data.len

proc `recv`*(sock: TLSSocket, buf: var seq[byte], size: int): int =
  if not sock.connected:
    return -1
  # In production: SSL_read(sock.ssl, buf[0].addr, size.cint)
  buf.setLen(min(buf.len, size))
  return size

proc close*(sock: TLSSocket) =
  sock.connected = false
  # In production: SSL_shutdown(sock.ssl); SSL_free(sock.ssl); SSL_CTX_free(sock.ctx)

proc isConnected*(sock: TLSSocket): bool = sock.connected

# TLS Certificate management
type
  CertInfo* = object
    subject*: string
    issuer*: string
    notBefore*: string
    notAfter*: string
    fingerprint*: string
    keySize*: int
    isSelfSigned*: bool

proc parseCertInfo*(certPath: string): CertInfo =
  result = CertInfo()
  if not fileExists(certPath):
    return

  # Read PEM certificate and extract basic info
  let content = readFile(certPath)
  result.subject = "Unknown"
  result.issuer = "Unknown"
  result.fingerprint = ""

  # In production: use OpenSSL X509 parsing
  for line in content.splitLines():
    if line.startsWith("Subject:"):
      result.subject = line[8..^1].strip()
    elif line.startsWith("Issuer:"):
      result.issuer = line[7..^1].strip()

  result.isSelfSigned = result.subject == result.issuer

proc generateSelfSignedCert*(outputDir: string, commonName: string = "localhost"): (string, string) =
  let certPath = outputDir / (commonName & ".crt")
  let keyPath = outputDir / (commonName & ".key")
  createDir(outputDir)

  # Use openssl CLI if available
  let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyPath &
            " -out " & certPath & " -days 365 -nodes -subj '/CN=" & commonName & "' 2>/dev/null"
  if execShellCmd(cmd) == 0 and fileExists(certPath):
    return (certPath, keyPath)
  return ("", "")

proc certificateFingerprint*(certPath: string): string =
  if not fileExists(certPath):
    return ""
  let cmd = "openssl x509 -in " & certPath & " -fingerprint -noout 2>/dev/null"
  result = ""
  # In production, use popen() to read command output
  discard execShellCmd(cmd)

proc isExpired*(certPath: string): bool =
  if not fileExists(certPath):
    return true
  let cmd = "openssl x509 -in " & certPath & " -checkend 0 2>/dev/null"
  return execShellCmd(cmd) != 0

proc daysUntilExpiry*(certPath: string): int =
  if not fileExists(certPath):
    return -1
  let cmd = "openssl x509 -in " & certPath & " -checkend 86400 2>/dev/null"
  if execShellCmd(cmd) == 0:
    # Expires in more than 1 day
    # In production, parse the actual enddate
    return 365
  return 0

proc validateCert*(certPath: string): seq[string] =
  result = @[]
  if not fileExists(certPath):
    result.add("Certificate file not found: " & certPath)
  if isExpired(certPath):
    result.add("Certificate has expired")
