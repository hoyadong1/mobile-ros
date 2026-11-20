"""Gemini planning for the agent proxy, through the Gemini API's REST endpoint (standard library only).

The app speaks the Messages-API conversation shape (system, tools, user/assistant turns with
tool_use / tool_result blocks). This module translates that to Gemini's generateContent request and
the answer back, so the app does not care which model plans.

Gemini models with thinking attach a thought signature to their parts and need those parts back
unchanged on the next turn. The answer therefore carries the model's raw parts in an extra
`gemini_parts` content block; the app ignores block types it does not know and echoes the whole
assistant turn back, and this module rebuilds the model turn from it.
"""
import json
import logging
import urllib.error
import urllib.request
import uuid

API = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
log = logging.getLogger("agent_proxy.gemini")


class GeminiError(Exception):
    def __init__(self, status, message, retryable=False):
        super().__init__(message)
        self.status = status
        self.retryable = retryable


def _schema(schema):
    """JSON Schema -> the OpenAPI subset Gemini's `parameters` accepts (no additionalProperties)."""
    if isinstance(schema, dict):
        return {k: _schema(v) for k, v in schema.items() if k != "additionalProperties"}
    if isinstance(schema, list):
        return [_schema(v) for v in schema]
    return schema


def to_request(body):
    """Messages-API style body -> generateContent request."""
    names = {}  # tool_use id -> function name, for functionResponse parts
    contents = []
    for message in body["messages"]:
        role, content = message.get("role"), message.get("content")
        if isinstance(content, str):
            contents.append({"role": "user" if role == "user" else "model", "parts": [{"text": content}]})
            continue
        blocks = [b for b in (content or []) if isinstance(b, dict)]
        if role == "assistant":
            for b in blocks:
                if b.get("type") == "tool_use":
                    names[b.get("id")] = b.get("name")
            raw = next((b["parts"] for b in blocks if b.get("type") == "gemini_parts"), None)
            if raw is None:  # a turn not produced by Gemini: rebuild it from the blocks
                raw = [{"text": b["text"]} for b in blocks if b.get("type") == "text" and b.get("text")]
                raw += [{"functionCall": {"name": b["name"], "args": b.get("input") or {}}}
                        for b in blocks if b.get("type") == "tool_use"]
            contents.append({"role": "model", "parts": raw or [{"text": ""}]})
        else:
            parts = []
            for b in blocks:
                if b.get("type") == "text":
                    parts.append({"text": b.get("text", "")})
                elif b.get("type") == "tool_result":
                    result = b.get("content")
                    images = []
                    if isinstance(result, list):  # text and image blocks (e.g. a camera picture)
                        images = [c for c in result if isinstance(c, dict) and c.get("type") == "image"]
                        result = "\n".join(c.get("text", "") for c in result if isinstance(c, dict) and c.get("type") == "text")
                    try:
                        result = json.loads(result) if isinstance(result, str) else result
                    except ValueError:
                        pass
                    response = result if isinstance(result, dict) else {"result": result}
                    call_id = b.get("tool_use_id") or ""
                    call = {"name": names.get(call_id, "unknown"), "response": response}
                    if call_id and not call_id.startswith("gemini:"):  # ids this module made up are not Gemini's
                        call["id"] = call_id
                    parts.append({"functionResponse": call})
                    for img in images:  # Gemini takes pictures as inline data parts next to the response
                        src = img.get("source") or {}
                        if src.get("type") == "base64" and src.get("data"):
                            parts.append({"inlineData": {"mimeType": src.get("media_type", "image/jpeg"),
                                                         "data": src["data"]}})
            contents.append({"role": "user", "parts": parts or [{"text": ""}]})
    return {
        "systemInstruction": {"parts": [{"text": body["system"]}]},
        "contents": contents,
        "tools": [{"functionDeclarations": [
            {"name": t["name"], "description": t.get("description", ""),
             "parameters": _schema(t.get("input_schema") or {"type": "object", "properties": {}})}
            for t in body["tools"]
        ]}],
    }


def from_response(data):
    """generateContent answer -> {stop_reason, content} in the app's shape."""
    feedback = data.get("promptFeedback") or {}
    candidates = data.get("candidates") or []
    if feedback.get("blockReason") or not candidates:
        return {"stop_reason": "refusal", "content": []}
    candidate = candidates[0]
    parts = (candidate.get("content") or {}).get("parts") or []
    content, calls = [], 0
    for p in parts:
        if p.get("thought"):
            continue  # thought summaries are not part of the reply
        if "text" in p and p["text"].strip():
            content.append({"type": "text", "text": p["text"]})
        elif "functionCall" in p:
            fc = p["functionCall"]
            calls += 1
            content.append({"type": "tool_use", "id": fc.get("id") or f"gemini:{uuid.uuid4().hex[:12]}",
                            "name": fc.get("name"), "input": fc.get("args") or {}})
    content.append({"type": "gemini_parts", "parts": parts})
    finish = candidate.get("finishReason", "STOP")
    if finish in ("SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"):
        stop = "refusal"
    elif finish == "MAX_TOKENS":
        stop = "max_tokens"
    elif calls:
        stop = "tool_use"
    else:
        stop = "end_turn"
    return {"stop_reason": stop, "content": content}


class GeminiProvider:
    def _call(self, payload):
        request = urllib.request.Request(
            API.format(model=self.model), data=payload,
            headers={"content-type": "application/json", "x-goog-api-key": self.api_key}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            try:
                message = json.loads(e.read()).get("error", {}).get("message", "")
            except ValueError:
                message = ""
            status = {400: 400, 401: 502, 403: 502, 404: 502, 429: 429}.get(e.code, 502)
            raise GeminiError(status, f"Gemini API error {e.code}: {message[:300]}",
                              retryable=e.code in (500, 503)) from None
        except (urllib.error.URLError, TimeoutError) as e:
            raise GeminiError(502, f"the proxy could not reach the Gemini API: {e}", retryable=True) from None

    name = "gemini"

    # Measured 2026-11-13 with a plain "Say hi": 3.5-flash-lite answered in ~1.5 s every time, while
    # 3.8-flash returned 503 (overloaded) and 3.5-flash / flash-latest sometimes did not answer within
    # 40 s. A robot command needs a quick answer, so the default is the fast, reliable one.
    def __init__(self, api_key, model="gemini-3.5-flash-lite", timeout=30, attempts=2):
        self.api_key = api_key
        self.model = model
        self.timeout = timeout
        self.attempts = attempts

    def plan(self, body):
        payload = json.dumps(to_request(body)).encode()
        for attempt in range(1, self.attempts + 1):
            try:
                data = self._call(payload)
                break
            except GeminiError as e:
                # Overload (503/500) and timeouts are often momentary: retry once, anything else at once.
                if not e.retryable or attempt == self.attempts:
                    raise
                log.warning("%s; retrying", e)
        result = from_response(data)
        usage = data.get("usageMetadata") or {}
        log.info("%s stop=%s in=%s out=%s", data.get("modelVersion", self.model), result["stop_reason"],
                 usage.get("promptTokenCount"), usage.get("candidatesTokenCount"))
        result["model"] = data.get("modelVersion", self.model)
        result["usage"] = {"input_tokens": usage.get("promptTokenCount"),
                           "output_tokens": usage.get("candidatesTokenCount")}
        return result
