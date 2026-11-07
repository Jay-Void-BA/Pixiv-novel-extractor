import http.client
import importlib.util
import json
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from email.message import Message
from io import BytesIO
from pathlib import Path

spec = importlib.util.spec_from_file_location("shiori_server", Path(__file__).parents[1] / "freebsd/shiori_server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "index.html").write_text("<h1>Shiori</h1>")
        self.server = module.create_server(root)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.token = self.server.state.token

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def request(self, method, path, body=None, headers=None, authorized=True):
        h = dict(headers or {})
        if authorized: h["Authorization"] = "Bearer " + self.token
        if isinstance(body, dict): body = json.dumps(body)
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request(method, path, body=body, headers=h)
        result = connection.getresponse()
        data = result.read()
        status = result.status
        connection.close()
        return status, data

    def test_configuration_not_exposed_to_remote_origins_or_rebound_host(self):
        self.assertEqual(self.request("GET", "/api/config")[0], 200)
        for headers in [{"Origin": "https://evil.example"}, {"Host": "evil.example"}, {"Sec-Fetch-Site": "cross-site"}]:
            self.assertEqual(self.request("GET", "/api/config", headers=headers)[0], 403)

    def test_unauthorized_control_and_arbitrary_proxy_paths_rejected(self):
        self.assertEqual(self.request("GET", "/api/session", authorized=False)[0], 403)
        for path in ["https://evil.example", "/ajax/user/123", "/ajax/novel/123?redirect=evil", "/ajax/novel/../123"]:
            from urllib.parse import quote
            self.assertEqual(self.request("GET", "/api/pixiv?path=" + quote(path))[0], 400)

    def test_pairing_is_scoped_one_use_and_clearable(self):
        status, data = self.request("POST", "/api/login")
        self.assertEqual(status, 200)
        pair_token = json.loads(data)["url"].split("#")[1]
        headers = {"Authorization": "Bearer " + pair_token, "Origin": "chrome-extension://abc"}
        status, _ = self.request("POST", "/session", {"session": "123456_session"}, headers, False)
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(self.request("GET", "/api/session")[1])["loggedIn"])
        self.assertEqual(self.request("POST", "/session", {"session": "123456_session"}, headers, False)[0], 403)
        self.assertEqual(self.request("DELETE", "/api/session")[0], 200)
        self.assertIsNone(self.server.state.session)

    def test_expired_and_invalid_sessions_rejected(self):
        self.request("POST", "/api/login")
        self.server.state.pair_deadline = time.monotonic() - 1
        headers = {"Authorization": "Bearer " + self.server.state.pair_token}
        self.assertEqual(self.request("POST", "/session", {"session": "123456_session"}, headers, False)[0], 403)
        for body in [{"session": "cookie\r\ninjection"}, {"session": "short"}, [], {"session": 123}]:
            self.assertEqual(self.request("POST", "/api/session", json.dumps(body))[0], 400)

    def test_path_traversal_and_remote_session_post_rejected(self):
        self.assertEqual(self.request("GET", "/%2e%2e/secret")[0], 403)
        self.assertEqual(self.request("POST", "/api/session", {"session": "123456_session"}, {"Origin": "https://evil.example"})[0], 403)
        self.assertEqual(self.request("POST", "/api/session", "x" * 3000)[0], 400)
        self.assertEqual(self.request("GET", "/")[0], 200)

    def test_rate_limit_header_is_forwarded_without_cookie_or_upstream_html(self):
        headers = Message()
        headers['Retry-After'] = '30'
        headers['Set-Cookie'] = 'synthetic_private_cookie'
        error = module.urllib.error.HTTPError('https://www.pixiv.net/ajax/novel/1',
            429, 'limited', headers, BytesIO(b'synthetic private upstream HTML'))
        with patch.object(module.urllib.request.OpenerDirector, 'open', side_effect=error):
            connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
            connection.request('GET', '/api/pixiv?path=/ajax/novel/1',
                headers={'Authorization': 'Bearer ' + self.token})
            result = connection.getresponse()
            self.assertEqual(result.status, 429)
            self.assertEqual(result.getheader('Retry-After'), '30')
            self.assertIsNone(result.getheader('Set-Cookie'))
            self.assertNotIn(b'synthetic private', result.read())
            connection.close()

    def test_inflight_old_session_response_is_discarded_after_logout(self):
        started, release = threading.Event(), threading.Event()
        class Upstream(BytesIO):
            status = 200
            def read(self, *args):
                started.set()
                release.wait(timeout=3)
                return super().read(*args)
        response = Upstream(b'{"body":"synthetic private content"}')
        result = []
        self.request('POST', '/api/session', {'session': 'synthetic_session_12345'})
        with patch.object(module.urllib.request.OpenerDirector, 'open', return_value=response):
            request = threading.Thread(target=lambda: result.append(
                self.request('GET', '/api/pixiv?path=/ajax/novel/1')))
            request.start()
            try:
                self.assertTrue(started.wait(timeout=2))
                self.assertEqual(self.request('DELETE', '/api/session')[0], 200)
            finally:
                release.set()
                request.join(timeout=3)
        self.assertEqual(result[0][0], 409)
        self.assertNotIn(b'synthetic private', result[0][1])


if __name__ == "__main__": unittest.main()
