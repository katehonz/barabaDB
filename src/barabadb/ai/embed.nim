## Embedding client — calls external embedding APIs
##
## Configurable HTTP client for generating vector embeddings from text.
## Supports OpenAI-compatible and Ollama APIs.

import std/httpclient
import std/json
import std/strutils
import std/os

type
  EmbedderConfig* = object
    endpoint*: string          # e.g. "http://localhost:11434/api/embeddings"
    model*: string            # e.g. "nomic-embed-text"
    apiKey*: string           # API key (for OpenAI-compatible APIs)
    dimensions*: int          # Expected embedding dimensions
    timeoutMs*: int           # Request timeout in ms
    enabled*: bool            # Whether auto-embedding is enabled

  Embedder* = ref object
    config*: EmbedderConfig

proc defaultEmbedderConfig*(): EmbedderConfig =
  EmbedderConfig(
    endpoint: getEnv("BARADB_EMBED_ENDPOINT", ""),
    model: getEnv("BARADB_EMBED_MODEL", "nomic-embed-text"),
    apiKey: getEnv("BARADB_EMBED_API_KEY", ""),
    dimensions: 768,
    timeoutMs: 30000,
    enabled: false,
  )

proc newEmbedder*(config: EmbedderConfig = defaultEmbedderConfig()): Embedder =
  result = Embedder(config: config)
  result.config.enabled = config.endpoint.len > 0

proc embed*(e: Embedder, text: string): seq[float32] =
  result = @[]
  if not e.config.enabled:
    return

  var client = newHttpClient(timeout = e.config.timeoutMs)
  try:
    var body = %*{"model": e.config.model, "prompt": text}
    if e.config.apiKey.len > 0:
      client.headers["Authorization"] = "Bearer " & e.config.apiKey
    client.headers["Content-Type"] = "application/json"

    let resp = client.request(e.config.endpoint, httpMethod = HttpPost, body = $body)
    let data = parseJson(resp.body)

    if data.hasKey("embedding"):
      for val in data["embedding"]:
        result.add(float32(val.getFloat()))
    elif data.hasKey("data") and data["data"].kind == JArray and data["data"].len > 0:
      for val in data["data"][0]["embedding"]:
        result.add(float32(val.getFloat()))
  except CatchableError:
    discard
  finally:
    client.close()

proc embedBatch*(e: Embedder, texts: seq[string]): seq[seq[float32]] =
  result = newSeq[seq[float32]](texts.len)
  for i, text in texts:
    result[i] = e.embed(text)

proc vectorToJson*(vec: seq[float32]): string =
  var parts: seq[string] = @[]
  for v in vec:
    parts.add($v)
  return "[" & parts.join(",") & "]"

proc jsonToVector*(s: string): seq[float32] =
  result = @[]
  var cleaned = s.strip()
  if cleaned.startsWith("[") and cleaned.endsWith("]"):
    cleaned = cleaned[1..^2]
  elif cleaned.startsWith("(") and cleaned.endsWith(")"):
    cleaned = cleaned[1..^2]
  for part in cleaned.split(","):
    let p = part.strip()
    if p.len > 0:
      try:
        result.add(parseFloat(p))
      except CatchableError:
        discard
