## Chunking — Text splitting for RAG pipelines
##
## Splits long text into overlapping chunks suitable for embedding.
## Strategies: paragraph, sentence, fixed-size with overlap.

import std/strutils
import std/sequtils
import std/json

type
  ChunkStrategy* = enum
    csParagraph = "paragraph"   # Split by double newlines
    csSentence = "sentence"     # Split by sentence boundaries
    csFixed = "fixed"           # Fixed-size with overlap
    csRecursive = "recursive"   # Try paragraph, then sentence, then fixed

  ChunkConfig* = object
    maxChunkSize*: int          # Max characters per chunk (default 1024)
    chunkOverlap*: int          # Character overlap between chunks (default 128)
    strategy*: ChunkStrategy    # Chunking strategy (default recursive)
    minChunkSize*: int          # Minimum chunk size (default 64)
    separators*: seq[string]    # Custom separators for recursive splitting

proc defaultChunkConfig*(): ChunkConfig =
  ChunkConfig(
    maxChunkSize: 1024,
    chunkOverlap: 128,
    strategy: csRecursive,
    minChunkSize: 64,
    separators: @["\n\n", "\n", ". ", "? ", "! ", "; ", ", ", " "],
  )

proc splitByParagraphs(text: string): seq[string] =
  result = @[]
  for para in text.split("\n\n"):
    let trimmed = para.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc splitBySentences(text: string): seq[string] =
  result = @[]
  var current = ""
  var i = 0
  while i < text.len:
    current.add(text[i])
    if text[i] in {'.', '?', '!'}:
      if i + 1 < text.len and text[i + 1] == ' ':
        inc i
        current.add(' ')
        let trimmed = current.strip()
        if trimmed.len > 0:
          result.add(trimmed)
        current = ""
    inc i
  let remaining = current.strip()
  if remaining.len > 0:
    result.add(remaining)

proc splitFixed(text: string, chunkSize: int, overlap: int): seq[string] =
  result = @[]
  if text.len <= chunkSize:
    if text.strip().len > 0:
      result.add(text.strip())
    return

  var pos = 0
  while pos < text.len:
    let endPos = min(pos + chunkSize, text.len)
    var chunk = text[pos ..< endPos]

    if endPos < text.len:
      var breakPos = chunk.rfind(". ")
      if breakPos < 0:
        breakPos = chunk.rfind("? ")
      if breakPos < 0:
        breakPos = chunk.rfind("! ")
      if breakPos < 0:
        breakPos = chunk.rfind("\n\n")
      if breakPos < 0:
        breakPos = chunk.rfind("\n")
      if breakPos < 0:
        breakPos = chunk.rfind(" ")
      if breakPos > chunkSize div 4:
        chunk = chunk[0 .. breakPos]
        pos += breakPos + 1
      else:
        pos += chunkSize - overlap
    else:
      pos = text.len

    let trimmed = chunk.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc chunk*(text: string, config: ChunkConfig = defaultChunkConfig()): seq[string] =
  if text.len <= config.minChunkSize:
    let trimmed = text.strip()
    if trimmed.len > 0:
      return @[trimmed]
    return @[]

  case config.strategy
  of csParagraph:
    result = splitByParagraphs(text)
  of csSentence:
    result = splitBySentences(text)
  of csFixed:
    result = splitFixed(text, config.maxChunkSize, config.chunkOverlap)
  of csRecursive:
    # Try paragraph first
    var paragraphs = splitByParagraphs(text)
    if paragraphs.len > 1:
      for para in paragraphs:
        if para.len > config.maxChunkSize:
          for sentence in splitBySentences(para):
            if sentence.len > config.maxChunkSize:
              result.add(splitFixed(sentence, config.maxChunkSize, config.chunkOverlap))
            else:
              result.add(sentence)
        else:
          result.add(para)
    else:
      var sentences = splitBySentences(text)
      if sentences.len > 1:
        for sentence in sentences:
          if sentence.len > config.maxChunkSize:
            result.add(splitFixed(sentence, config.maxChunkSize, config.chunkOverlap))
          else:
            result.add(sentence)
      else:
        result = splitFixed(text, config.maxChunkSize, config.chunkOverlap)

  result = result.filterIt(it.len >= config.minChunkSize)

proc chunkToJson*(text: string, config: ChunkConfig = defaultChunkConfig()): JsonNode =
  let chunks = chunk(text, config)
  var arr = newJArray()
  var idx = 0
  for c in chunks:
    arr.add(%*{"index": idx, "text": c, "size": c.len})
    inc idx
  return arr
