"""Unit tests for the Messages-API <-> Gemini translation (no network).  python tool/gemini_provider_test.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gemini_provider import from_response, to_request  # noqa: E402

TOOLS = [{"name": "move", "description": "Drive.", "input_schema": {
    "type": "object", "properties": {"distance_m": {"type": "number", "minimum": -2, "maximum": 2}},
    "required": ["distance_m"], "additionalProperties": False}}]


class ToRequest(unittest.TestCase):
    def test_conversation_with_tool_results(self):
        raw_parts = [{"functionCall": {"name": "move", "args": {"distance_m": 0.3}, "id": "fc1"},
                      "thoughtSignature": "sig"}]
        body = {"system": "sys", "tools": TOOLS, "messages": [
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": [
                {"type": "tool_use", "id": "fc1", "name": "move", "input": {"distance_m": 0.3}},
                {"type": "gemini_parts", "parts": raw_parts}]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "fc1", "content": '{"ok": true, "message": "Moved"}'}]},
        ]}
        req = to_request(body)
        self.assertEqual(req["systemInstruction"], {"parts": [{"text": "sys"}]})
        self.assertEqual(req["contents"][0], {"role": "user", "parts": [{"text": "go"}]})
        self.assertEqual(req["contents"][1], {"role": "model", "parts": raw_parts},
                         "model turns go back exactly as Gemini sent them (thought signature)")
        self.assertEqual(req["contents"][2]["parts"], [{"functionResponse": {
            "name": "move", "response": {"ok": True, "message": "Moved"}, "id": "fc1"}}])
        params = req["tools"][0]["functionDeclarations"][0]["parameters"]
        self.assertNotIn("additionalProperties", params)
        self.assertEqual(params["properties"]["distance_m"]["maximum"], 2)

    def test_made_up_ids_are_not_sent_and_foreign_turns_are_rebuilt(self):
        body = {"system": "s", "tools": TOOLS, "messages": [
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": [
                {"type": "text", "text": "ok"},
                {"type": "tool_use", "id": "gemini:abc", "name": "move", "input": {"distance_m": 1}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "gemini:abc", "content": "done"}]},
        ]}
        req = to_request(body)
        self.assertEqual(req["contents"][1]["parts"],
                         [{"text": "ok"}, {"functionCall": {"name": "move", "args": {"distance_m": 1}}}])
        self.assertEqual(req["contents"][2]["parts"],
                         [{"functionResponse": {"name": "move", "response": {"result": "done"}}}])


class ToolResultImages(unittest.TestCase):
    def test_a_picture_in_a_tool_result_becomes_an_inline_data_part(self):
        body = {"system": "s", "tools": TOOLS, "messages": [
            {"role": "user", "content": "what do you see"},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "l1", "name": "look", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "l1", "content": [
                {"type": "text", "text": '{"ok": true, "message": "Took a picture"}'},
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "AAEC"}},
            ]}]},
        ]}
        parts = to_request(body)["contents"][2]["parts"]
        self.assertEqual(parts[0]["functionResponse"]["response"], {"ok": True, "message": "Took a picture"})
        self.assertEqual(parts[1], {"inlineData": {"mimeType": "image/jpeg", "data": "AAEC"}})


class FromResponse(unittest.TestCase):
    def test_calls_text_and_raw_parts(self):
        parts = [{"text": "thinking...", "thought": True}, {"text": "Moving."},
                 {"functionCall": {"name": "move", "args": {"distance_m": 0.3}}, "thoughtSignature": "s"}]
        out = from_response({"candidates": [{"content": {"parts": parts}, "finishReason": "STOP"}]})
        self.assertEqual(out["stop_reason"], "tool_use")
        types = [b["type"] for b in out["content"]]
        self.assertEqual(types, ["text", "tool_use", "gemini_parts"])
        self.assertEqual(out["content"][0]["text"], "Moving.")
        call = out["content"][1]
        self.assertTrue(call["id"].startswith("gemini:"))
        self.assertEqual((call["name"], call["input"]), ("move", {"distance_m": 0.3}))
        self.assertEqual(out["content"][2]["parts"], parts)

    def test_stop_reasons(self):
        def stop(data):
            return from_response(data)["stop_reason"]
        text = {"content": {"parts": [{"text": "hi"}]}}
        self.assertEqual(stop({"candidates": [{**text, "finishReason": "STOP"}]}), "end_turn")
        self.assertEqual(stop({"candidates": [{**text, "finishReason": "MAX_TOKENS"}]}), "max_tokens")
        self.assertEqual(stop({"candidates": [{**text, "finishReason": "SAFETY"}]}), "refusal")
        self.assertEqual(stop({"promptFeedback": {"blockReason": "SAFETY"}}), "refusal")


if __name__ == "__main__":
    unittest.main()
