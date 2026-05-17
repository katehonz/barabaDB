## LLM Client — calls external LLM APIs for NL→SQL generation
##
## Supports OpenAI-compatible and Ollama APIs.
## Used by the `nl_to_sql()` SQL function.

import std/httpclient
import std/json
import std/strutils
import std/os

type
  LLMConfig* = object
    endpoint*: string          # e.g. "http://localhost:11434/api/generate"
    chatEndpoint*: string      # e.g. "https://api.openai.com/v1/chat/completions"
    model*: string            # e.g. "llama3", "gpt-4o-mini"
    apiKey*: string
    timeoutMs*: int
    enabled*: bool
    maxTokens*: int

  LLMClient* = ref object
    config*: LLMConfig

proc defaultLLMConfig*(): LLMConfig =
  LLMConfig(
    endpoint: getEnv("BARADB_LLM_ENDPOINT", ""),
    chatEndpoint: getEnv("BARADB_LLM_CHAT_ENDPOINT", ""),
    model: getEnv("BARADB_LLM_MODEL", "llama3"),
    apiKey: getEnv("BARADB_LLM_API_KEY", ""),
    timeoutMs: 60000,
    enabled: false,
    maxTokens: 2048,
  )

proc newLLMClient*(config: LLMConfig = defaultLLMConfig()): LLMClient =
  result = LLMClient(config: config)
  result.config.enabled = config.endpoint.len > 0 or config.chatEndpoint.len > 0

proc generate*(client: LLMClient, prompt: string, systemPrompt: string = ""): string =
  result = ""
  if not client.config.enabled:
    return

  var httpClient = newHttpClient(timeout = client.config.timeoutMs)
  try:
    if client.config.apiKey.len > 0:
      httpClient.headers["Authorization"] = "Bearer " & client.config.apiKey
    httpClient.headers["Content-Type"] = "application/json"

    if client.config.chatEndpoint.len > 0:
      var messages = newJArray()
      if systemPrompt.len > 0:
        messages.add(%*{"role": "system", "content": systemPrompt})
      messages.add(%*{"role": "user", "content": prompt})
      let body = %*{
        "model": client.config.model,
        "messages": messages,
        "max_tokens": client.config.maxTokens,
        "temperature": 0.1,
      }
      let resp = httpClient.request(client.config.chatEndpoint, httpMethod = HttpPost, body = $body)
      let data = parseJson(resp.body)
      if data.hasKey("choices") and data["choices"].kind == JArray and data["choices"].len > 0:
        result = data["choices"][0]["message"]["content"].getStr()
    elif client.config.endpoint.len > 0:
      var fullPrompt = prompt
      if systemPrompt.len > 0:
        fullPrompt = systemPrompt & "\n\n" & prompt
      let body = %*{
        "model": client.config.model,
        "prompt": fullPrompt,
        "stream": false,
        "options": {"temperature": 0.1, "num_predict": client.config.maxTokens},
      }
      let resp = httpClient.request(client.config.endpoint, httpMethod = HttpPost, body = $body)
      let data = parseJson(resp.body)
      if data.hasKey("response"):
        result = data["response"].getStr()
      elif data.hasKey("choices") and data["choices"].kind == JArray and data["choices"].len > 0:
        result = data["choices"][0]["message"]["content"].getStr()
  except CatchableError:
    result = ""
  finally:
    httpClient.close()

proc extractSQL*(response: string): string =
  ## Extract SQL from LLM response which may contain markdown or explanations.
  result = response.strip()

  # Try markdown code block: ```sql ... ```
  var start = result.find("```sql")
  if start < 0:
    start = result.find("```SQL")
  if start < 0:
    start = result.find("```")
  if start >= 0:
    var endPos = result.find("```", start + 3)
    if endPos < 0:
      endPos = result.len
    result = result[start + 3 ..< endPos].strip()
    # Strip leading "sql" or "SQL" if present after ```
    if result.toLower().startsWith("sql"):
      result = result[3..^1].strip()

  # Remove trailing semicolons and whitespace
  result = result.strip(chars = {';', ' ', '\n', '\r', '\t'})

  # If there's a SELECT/INSERT/UPDATE/DELETE/CREATE anywhere, start from there
  let sqlStart = result.toLower().find("select")
  if sqlStart < 0:
    let altStart = result.toLower().find("insert")
    if altStart < 0:
      let altStart2 = result.toLower().find("update")
      if altStart2 < 0:
        let altStart3 = result.toLower().find("delete")
        if altStart3 < 0:
          let altStart4 = result.toLower().find("create")
          if altStart4 >= 0:
            result = result[altStart4..^1]
        else:
          result = result[altStart3..^1]
      else:
        result = result[altStart2..^1]
    else:
      result = result[altStart..^1]
  elif sqlStart > 0:
    result = result[sqlStart..^1]

  return result
