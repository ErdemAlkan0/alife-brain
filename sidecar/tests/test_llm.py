import json
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from alifebrain_sidecar.config import Settings
from alifebrain_sidecar.llm import LLMError, OpenAICompatibleProvider, Player2Provider, build_provider


class FakeApi(BaseHTTPRequestHandler):
    """Speaks just enough of the OpenAI / Player2 API for the providers."""

    mode = "ok"
    seen: list = []

    def log_message(self, *args):
        pass

    def lower_headers(self):
        return {key.lower(): value for key, value in self.headers.items()}

    def _send(self, code, body):
        data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        FakeApi.seen.append(("GET", self.path, self.lower_headers(), None))
        self._send(200, {"client_version": "test"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeApi.seen.append(("POST", self.path, self.lower_headers(), body))
        if FakeApi.mode == "rate_limited":
            return self._send(429, {"error": "slow down"})
        if FakeApi.mode in ("reject_once", "reject_always"):
            if FakeApi.mode == "reject_once":
                FakeApi.mode = "ok"
            return self._send(400, {"message": "user input rejected (HTTP 400): API returned unexpected status code"})
        if FakeApi.mode == "garbage":
            return self._send(200, b"<html>")
        if FakeApi.mode == "slow":
            time.sleep(1.5)
        self._send(200, {"choices": [{"message": {"role": "assistant", "content": '{"say": "Hi."}'}}]})


class QuietServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # the timeout test drops connections on purpose


class ProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = QuietServer(("127.0.0.1", 0), FakeApi)
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}/v1"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        FakeApi.mode = "ok"
        FakeApi.seen = []

    def chat(self, provider, timeout=5.0):
        return provider.chat([{"role": "user", "content": "hi"}], max_tokens=50, temperature=0.5, timeout=timeout)

    def test_player2_sends_game_key_and_only_messages(self):
        provider = Player2Provider(self.url, "my-client-id")
        self.assertEqual(self.chat(provider), '{"say": "Hi."}')
        method, path, headers, body = FakeApi.seen[-1]
        self.assertEqual((method, path), ("POST", "/v1/chat/completions"))
        self.assertEqual(headers.get("player2-game-key"), "my-client-id")
        self.assertEqual(body, {"messages": [{"role": "user", "content": "hi"}]})

    def test_player2_health(self):
        self.assertEqual(Player2Provider(self.url, "id").health(), {"client_version": "test"})
        self.assertEqual(FakeApi.seen[-1][1], "/v1/health")

    def test_player2_without_client_id_fails_before_any_request(self):
        with self.assertRaises(LLMError) as caught:
            self.chat(Player2Provider(self.url, ""))
        self.assertEqual(caught.exception.code, "player2_client_id_missing")
        self.assertEqual(FakeApi.seen, [])

    def test_openai_compatible_sends_model_sampling_and_json_mode(self):
        provider = OpenAICompatibleProvider(self.url, model="m1", headers={"Authorization": "Bearer k"})
        self.chat(provider)
        _, _, headers, body = FakeApi.seen[-1]
        self.assertEqual(headers.get("authorization"), "Bearer k")
        self.assertEqual(body["model"], "m1")
        self.assertEqual(body["max_tokens"], 50)
        self.assertEqual(body["response_format"], {"type": "json_object"})

    def test_error_codes(self):
        provider = Player2Provider(self.url, "id")
        for mode, code in [("rate_limited", "rate_limited"), ("garbage", "bad_response")]:
            FakeApi.mode = mode
            with self.subTest(mode=mode), self.assertRaises(LLMError) as caught:
                self.chat(provider)
            self.assertEqual(caught.exception.code, code)

    def test_player2_retries_a_quick_rejection_once(self):
        provider = Player2Provider(self.url, "id")
        FakeApi.mode = "reject_once"
        self.assertEqual(self.chat(provider), '{"say": "Hi."}')
        self.assertEqual(len([entry for entry in FakeApi.seen if entry[0] == "POST"]), 2)
        FakeApi.mode, FakeApi.seen = "reject_always", []
        with self.assertRaises(LLMError) as caught:
            self.chat(provider)
        self.assertEqual(caught.exception.code, "http_400")
        self.assertEqual(len(FakeApi.seen), 2, "only one retry")

    def test_timeout(self):
        FakeApi.mode = "slow"
        with self.assertRaises(LLMError) as caught:
            self.chat(Player2Provider(self.url, "id"), timeout=0.3)
        self.assertEqual(caught.exception.code, "timeout")

    def test_unreachable(self):
        with self.assertRaises(LLMError) as caught:
            self.chat(Player2Provider("http://127.0.0.1:9/v1", "id"), timeout=5)
        self.assertEqual(caught.exception.code, "unreachable")


class BuildProviderTests(unittest.TestCase):
    def test_openai_key_comes_only_from_the_environment(self):
        settings = Settings(provider="openai")
        with self.assertRaises(LLMError) as caught:
            build_provider(settings, environ={})
        self.assertEqual(caught.exception.code, "api_key_missing")
        provider = build_provider(settings, environ={"OPENAI_API_KEY": "secret"})
        self.assertEqual(provider.headers["Authorization"], "Bearer secret")

    def test_fake_provider_echoes_valid_json(self):
        provider = build_provider(Settings(provider="fake"))
        reply = json.loads(provider.chat([{"role": "user", "content": 'The stranger says: "hello"'}],
                                         max_tokens=1, temperature=0, timeout=1))
        self.assertIn("hello", reply["say"])


if __name__ == "__main__":
    unittest.main()
