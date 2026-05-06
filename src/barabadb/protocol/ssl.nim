## TLS/SSL Wrapper — encrypted sockets using OpenSSL (Nim stdlib)
when not defined(ssl):
  {.error: "BaraDB requires SSL support. Compile with -d:ssl".}

import std/os
import std/osproc
import std/strutils
import std/net
import std/asyncnet

type
  TLSConfig* = object
    certFile*: string
    keyFile*: string
    caFile*: string
    verifyPeer*: bool

  TLSContext* = ref object
    sslCtx*: SslContext
    config*: TLSConfig

proc newTLSConfig*(certFile: string, keyFile: string, caFile: string = "",
                   verifyPeer: bool = false): TLSConfig =
  TLSConfig(
    certFile: certFile, keyFile: keyFile,
    caFile: caFile, verifyPeer: verifyPeer,
  )

proc newTLSContext*(config: TLSConfig): TLSContext =
  result = TLSContext(config: config)
  if fileExists(config.certFile) and fileExists(config.keyFile):
    result.sslCtx = newContext(
      certFile = config.certFile,
      keyFile = config.keyFile,
    )
  else:
    raise newException(IOError, "TLS certificate or key file not found: " &
      config.certFile & ", " & config.keyFile)

proc wrapClient*(tls: TLSContext, socket: AsyncSocket) {.inline.} =
  if tls.sslCtx != nil:
    tls.sslCtx.wrapSocket(socket)

proc wrapServer*(tls: TLSContext, socket: AsyncSocket) {.inline.} =
  if tls.sslCtx != nil:
    tls.sslCtx.wrapConnectedSocket(socket, handshakeAsServer)

proc close*(tls: TLSContext) =
  if tls.sslCtx != nil:
    tls.sslCtx.destroyContext()

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
  let content = readFile(certPath)
  result.subject = "Unknown"
  result.issuer = "Unknown"
  result.fingerprint = ""
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
  let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyPath &
            " -out " & certPath & " -days 365 -nodes -subj '/CN=" & commonName & "' 2>/dev/null"
  if execShellCmd(cmd) == 0 and fileExists(certPath):
    return (certPath, keyPath)
  return ("", "")

proc certificateFingerprint*(certPath: string): string =
  if not fileExists(certPath):
    return ""
  let cmd = "openssl x509 -in " & certPath & " -fingerprint -noout 2>/dev/null"
  let (output, _) = execCmdEx(cmd)
  for line in output.splitLines():
    if "Fingerprint=" in line:
      let parts = line.split("Fingerprint=")
      if parts.len > 1:
        return parts[^1].strip()
  return ""

proc isExpired*(certPath: string): bool =
  if not fileExists(certPath):
    return true
  let cmd = "openssl x509 -in " & certPath & " -checkend 0 2>/dev/null"
  return execShellCmd(cmd) != 0

proc daysUntilExpiry*(certPath: string): int =
  if not fileExists(certPath):
    return -1
  # Check if expires within 1 day
  let cmd1 = "openssl x509 -in " & certPath & " -checkend 86400 2>/dev/null"
  if execShellCmd(cmd1) == 0:
    # Check if expires within 30 days
    let cmd30 = "openssl x509 -in " & certPath & " -checkend 2592000 2>/dev/null"
    if execShellCmd(cmd30) == 0:
      return 365
    return 30
  return 1

proc validateCert*(certPath: string): seq[string] =
  result = @[]
  if not fileExists(certPath):
    result.add("Certificate file not found: " & certPath)
  if isExpired(certPath):
    result.add("Certificate has expired")
