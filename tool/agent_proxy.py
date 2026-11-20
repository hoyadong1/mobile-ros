#!/usr/bin/env python3
"""Developer proxy between the Mobile ROS app and a language model API (Claude or Gemini).

The app must never hold an API key, so it sends its agent conversation here and this proxy calls the
model. The model and limits are fixed here; the app only supplies the system prompt, the robot's
skills (as tools) and the conversation, always in the Messages-API shape.

Claude (official anthropic SDK):
    pip install anthropic
    export ANTHROPIC_API_KEY=...          # or `ant auth login`
    python tool/agent_proxy.py --token some-shared-secret

Gemini (REST, standard library only):
    python tool/agent_proxy.py --provider gemini --key-file ~/gemini-key.txt --token some-shared-secret
    # or GEMINI_API_KEY=... in the environment; --model picks another model (default gemini-flash-latest)

In the app (AI assistant > settings): proxy URL http://<PC IP>:8787/v1/plan and the same token.
Bind to 127.0.0.1 (--host) when only a browser on this PC uses it. Anyone who can reach the port and
knows the token spends your API credit, so keep it on a trusted network.

POST /v1/plan   {"system": str, "tools": [...], "messages": [...]}
  -> 200 {"stop_reason": str, "content": [blocks], "model": str, "usage": {...}}
  -> 4xx/5xx {"error": str}
"""
import argparse
import json
import logging
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 8_000_000  # room for a camera picture in a tool result
log = logging.getLogger("agent_proxy")


class ProxyError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def check_body(body):
    if (not isinstance(body, dict) or not isinstance(body.get("system"), str)
            or not isinstance(body.get("tools"), list) or not isinstance(body.get("messages"), list)
            or not body["messages"]):
        raise ValueError("expected {system: str, tools: [...], messages: [...]}")


# ---------------------------------------------------------------------------------------- Claude

# Blocks that come from the model that declined, when a refusal fallback happened mid-output.
_DROP_BEFORE_FALLBACK = {"thinking", "redacted_thinking", "tool_use"}


def echo_safe(blocks):
    """Content the app can both act on and send back next turn. After a mid-output fallback, thinking
    and tool_use blocks before the last `fallback` block belong to the declined attempt: they must not
    run and must not be echoed (an unpaired server_tool_use likewise). The fallback block stays in
    place, since the API validates thinking around it by its position."""
    last = max((i for i, b in enumerate(blocks) if b.get("type") == "fallback"), default=-1)
    if last < 0:
        return blocks
    paired = {b.get("tool_use_id") for b in blocks[:last] if str(b.get("type", "")).endswith("_tool_result")}
    kept = []
    for i, b in enumerate(blocks):
        t = b.get("type")
        if i < last and (t in _DROP_BEFORE_FALLBACK or (t == "server_tool_use" and b.get("id") not in paired)):
            continue
        kept.append(b)
    return kept


class ClaudeProvider:
    name = "claude"
    MAX_TOKENS = 16000
    # Robot commands are short and the person is waiting with a robot in front of them: low effort
    # keeps replies quick. Raise it if multi-step plans need more care.
    EFFORT = "low"

    def __init__(self, model="claude-opus-5-5"):
        import anthropic  # only needed for this provider
        self.anthropic = anthropic
        self.client = anthropic.Anthropic()
        self.model = model

    def plan(self, body):
        a = self.anthropic
        try:
            response = self.client.beta.messages.create(
                model=self.model,
                max_tokens=self.MAX_TOKENS,
                output_config={"effort": self.EFFORT},
                # On a safety refusal, the API re-runs the request on a fallback model chosen per category.
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                # Cache the stable prefix (tools + system prompt) across the turns of an instruction.
                system=[{"type": "text", "text": body["system"], "cache_control": {"type": "ephemeral"}}],
                tools=body["tools"],
                messages=body["messages"],
            )
        except TypeError as e:  # e.g. no API key configured for the SDK
            raise ProxyError(502, f"the proxy cannot call the Claude API: {e}") from None
        except a.AuthenticationError:
            raise ProxyError(502, "the proxy's API key was rejected") from None
        except a.RateLimitError:
            raise ProxyError(429, "rate limited by the Claude API; try again shortly") from None
        except a.BadRequestError as e:
            raise ProxyError(400, f"Claude API rejected the request: {e.message}") from None
        except a.APIStatusError as e:
            raise ProxyError(502, f"Claude API error {e.status_code}: {e.message}") from None
        except a.APIConnectionError:
            raise ProxyError(502, "the proxy could not reach the Claude API") from None
        log.info("%s stop=%s in=%s out=%s cached=%s req=%s", response.model, response.stop_reason,
                 response.usage.input_tokens, response.usage.output_tokens,
                 response.usage.cache_read_input_tokens, response._request_id)
        return {
            "stop_reason": response.stop_reason,
            "content": echo_safe([block.to_dict() for block in response.content]),
            "model": response.model,
            "usage": {"input_tokens": response.usage.input_tokens, "output_tokens": response.usage.output_tokens},
        }


# ---------------------------------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    token = ""
    provider = None

    def do_POST(self):
        if self.path != "/v1/plan":
            return self._send(404, {"error": "not found"})
        if self.token and self.headers.get("x-proxy-token") != self.token:
            return self._send(401, {"error": "missing or wrong X-Proxy-Token"})
        length = int(self.headers.get("content-length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._send(400, {"error": "empty or too large request"})
        try:
            body = json.loads(self.rfile.read(length))
            check_body(body)
            return self._send(200, self.provider.plan(body))
        except ValueError as e:  # bad request body (also JSON decode errors)
            return self._send(400, {"error": str(e)})
        except Exception as e:  # provider errors carry the status to answer with
            status = getattr(e, "status", None)
            if status is None:
                log.exception("unexpected error")
                return self._send(500, {"error": f"proxy error: {type(e).__name__}"})
            return self._send(status, {"error": str(e)})

    def do_OPTIONS(self):  # browser (web build) preflight
        self._send(204, None)

    def _send(self, status, payload):
        data = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-headers", "content-type, x-proxy-token")
        self.send_header("access-control-allow-methods", "POST, OPTIONS")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


def make_provider(args):
    if args.provider == "claude":
        return ClaudeProvider(**({"model": args.model} if args.model else {}))
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from gemini_provider import GeminiProvider
    key = os.environ.get("GEMINI_API_KEY", "")
    if args.key_file:
        with open(os.path.expanduser(args.key_file), encoding="utf-8") as f:
            key = f.read().strip()
    if not key:
        sys.exit("Gemini needs a key: --key-file <file> or GEMINI_API_KEY")
    return GeminiProvider(key, **({"model": args.model} if args.model else {}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--provider", choices=["claude", "gemini"], default="claude")
    parser.add_argument("--model", default="", help="override the provider's default model")
    parser.add_argument("--key-file", default="", help="Gemini: file holding the API key")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--token", default="", help="shared secret the app sends as X-Proxy-Token")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    if not args.token and args.host != "127.0.0.1":
        log.warning("no --token: anyone on this network can use your API credit through this proxy")
    Handler.token = args.token
    Handler.provider = make_provider(args)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    log.info("agent proxy on http://%s:%d/v1/plan (%s, model %s)", args.host, args.port,
             Handler.provider.name, Handler.provider.model)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
