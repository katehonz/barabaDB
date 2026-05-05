## TLS/SSL — transport layer security wrapper
import std/os
import std/strutils

type
  TLSVersion* = enum
    tls12 = "TLSv1.2"
    tls13 = "TLSv1.3"

  TLSConfig* = object
    certFile*: string
    keyFile*: string
    caFile*: string
    minVersion*: TLSVersion
    verifyPeer*: bool
    cipherSuites*: seq[string]

  TLSState* = enum
    tsDisconnected
    tsHandshaking
    tsConnected
    tsError

  TLSConnection* = ref object
    config*: TLSConfig
    state*: TLSState
    host*: string
    port*: int

proc defaultTLSConfig*(): TLSConfig =
  TLSConfig(
    certFile: "",
    keyFile: "",
    caFile: "",
    minVersion: tls12,
    verifyPeer: false,
    cipherSuites: @[
      "TLS_AES_256_GCM_SHA384",
      "TLS_CHACHA20_POLY1305_SHA256",
      "TLS_AES_128_GCM_SHA256",
    ],
  )

proc newTLSConfig*(certFile, keyFile: string, caFile: string = "",
                   minVersion: TLSVersion = tls12,
                   verifyPeer: bool = false): TLSConfig =
  TLSConfig(
    certFile: certFile,
    keyFile: keyFile,
    caFile: caFile,
    minVersion: minVersion,
    verifyPeer: verifyPeer,
    cipherSuites: @[
      "TLS_AES_256_GCM_SHA384",
      "TLS_CHACHA20_POLY1305_SHA256",
      "TLS_AES_128_GCM_SHA256",
    ],
  )

proc validateConfig*(config: TLSConfig): seq[string] =
  result = @[]
  if config.certFile.len == 0:
    result.add("Certificate file not specified")
  elif not fileExists(config.certFile):
    result.add("Certificate file not found: " & config.certFile)
  if config.keyFile.len == 0:
    result.add("Key file not specified")
  elif not fileExists(config.keyFile):
    result.add("Key file not found: " & config.keyFile)
  if config.caFile.len > 0 and not fileExists(config.caFile):
    result.add("CA file not found: " & config.caFile)

proc isValid*(config: TLSConfig): bool =
  return config.validateConfig().len == 0

proc newTLSConnection*(config: TLSConfig, host: string, port: int): TLSConnection =
  TLSConnection(config: config, state: tsDisconnected, host: host, port: port)

proc state*(conn: TLSConnection): TLSState = conn.state

# Self-signed certificate generation helper
proc generateSelfSignedCert*(outputDir: string): (string, string) =
  let certPath = outputDir / "server.crt"
  let keyPath = outputDir / "server.key"

  createDir(outputDir)
  # Use openssl to generate self-signed cert
  let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyPath &
            " -out " & certPath & " -days 365 -nodes -subj '/CN=localhost' 2>/dev/null"
  discard execShellCmd(cmd)

  return (certPath, keyPath)

proc certificateInfo*(certPath: string): Table[string, string] =
  result = initTable[string, string]()
  if not fileExists(certPath):
    return
  # Would use openssl to parse cert in production
  result["path"] = certPath
  result["exists"] = "true"
