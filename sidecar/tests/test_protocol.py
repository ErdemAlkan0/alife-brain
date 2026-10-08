import json
import unittest

from alifebrain_sidecar.protocol import (
    MAX_LINE_LENGTH,
    Ack,
    ProtocolError,
    encode_line,
    parse_request,
    response_payload,
)


def line(**overrides):
    message = {"v": 1, "id": "s1:1", "sess": "s1", "type": "ping", "ts": 1000, "data": {"n": 1}}
    message.update(overrides)
    return json.dumps(message)


class ParseRequestTests(unittest.TestCase):
    def test_valid_request(self):
        request = parse_request(line(ack={"sid": "abc", "rseq": 4}))
        self.assertEqual(request.id, "s1:1")
        self.assertEqual(request.session, "s1")
        self.assertEqual(request.type, "ping")
        self.assertEqual(request.ts, 1000)
        self.assertEqual(request.data, {"n": 1})
        self.assertEqual(request.ack, Ack(sid="abc", rseq=4))

    def test_data_and_ack_are_optional(self):
        message = json.loads(line())
        del message["data"]
        request = parse_request(json.dumps(message))
        self.assertIsNone(request.data)
        self.assertIsNone(request.ack)

    def test_rejects_malformed_lines(self):
        bad = [
            "not json",
            "[1,2]",
            line(v=2),
            line(type="Ping"),
            line(type=""),
            line(id=""),
            line(id=5),
            line(sess=None),
            line(ts="now"),
            line(ts=True),
            line(ack={"sid": "x", "rseq": -1}),
            line(ack={"sid": "x", "rseq": 1.5}),
            line(ack="x"),
            "x" * (MAX_LINE_LENGTH + 1),
        ]
        for text in bad:
            with self.subTest(text=text[:60]):
                with self.assertRaises(ProtocolError):
                    parse_request(text)

    def test_accepts_float_timestamps_from_lua(self):
        self.assertEqual(parse_request(line(ts=1759951234567.0)).ts, 1759951234567)


class EncodeTests(unittest.TestCase):
    def test_encoded_lines_are_ascii_and_single_line(self):
        text = encode_line(response_payload(rseq=1, re_id="s:1", ok=True, data={"say": "Merhaba, nasılsın?\nİyi."}))
        text.encode("ascii")
        self.assertNotIn("\n", text)
        self.assertIn("\\u0131", text)
        self.assertEqual(json.loads(text)["data"]["say"], "Merhaba, nasılsın?\nİyi.")

    def test_error_responses_carry_error_not_data(self):
        payload = response_payload(rseq=2, re_id="s:2", ok=False, error="unknown_type")
        self.assertEqual(payload["error"], "unknown_type")
        self.assertNotIn("data", payload)


if __name__ == "__main__":
    unittest.main()
