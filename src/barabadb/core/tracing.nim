## Tracing — lightweight OpenTelemetry-compatible span recording
import std/json
import std/times
import std/monotimes
import std/tables

type
  SpanStatus* = enum
    ssOk = "OK"
    ssError = "ERROR"

  Span* = ref object
    traceId*: string
    spanId*: string
    parentSpanId*: string
    name*: string
    startTime*: int64    # monotonic ticks
    endTime*: int64
    durationMs*: float64
    status*: SpanStatus
    attributes*: Table[string, string]

  Tracer* = ref object
    spans*: seq[Span]
    activeSpan*: Span
    enabled*: bool
    nextId*: uint64

var defaultTracer* = Tracer(spans: @[], activeSpan: nil, enabled: false, nextId: 1)

proc genId(tracer: Tracer): string =
  result = $tracer.nextId
  inc tracer.nextId

proc beginSpan*(tracer: Tracer, name: string, attributes: Table[string, string] = initTable[string, string]()): Span =
  if not tracer.enabled: return nil
  let span = Span(
    traceId: if tracer.activeSpan != nil: tracer.activeSpan.traceId else: genId(tracer),
    spanId: genId(tracer),
    parentSpanId: if tracer.activeSpan != nil: tracer.activeSpan.spanId else: "",
    name: name,
    startTime: getMonoTime().ticks(),
    attributes: attributes,
  )
  tracer.spans.add(span)
  tracer.activeSpan = span
  return span

proc endSpan*(tracer: Tracer, span: Span, status: SpanStatus = ssOk) =
  if span == nil or not tracer.enabled: return
  span.endTime = getMonoTime().ticks()
  span.durationMs = float64(span.endTime - span.startTime) / 1_000_000.0
  span.status = status
  if span.parentSpanId.len > 0:
    for s in tracer.spans:
      if s.spanId == span.parentSpanId:
        tracer.activeSpan = s
        return
  tracer.activeSpan = nil

proc setSpanError*(span: Span, msg: string) =
  if span == nil: return
  span.status = ssError
  span.attributes["error.message"] = msg

proc flushSpans*(tracer: Tracer): JsonNode =
  result = newJArray()
  for span in tracer.spans:
    result.add(%*{
      "traceId": span.traceId,
      "spanId": span.spanId,
      "parentSpanId": span.parentSpanId,
      "name": span.name,
      "durationMs": span.durationMs,
      "status": $span.status,
      "attributes": span.attributes,
    })
  tracer.spans = @[]

proc enable*(tracer: Tracer) =
  tracer.enabled = true

proc disable*(tracer: Tracer) =
  tracer.enabled = false
