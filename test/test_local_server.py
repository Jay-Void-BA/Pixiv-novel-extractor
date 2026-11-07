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


class MemoryKeyring:
    def __init__(self):
        self.values = {}

    def get_password(self, service, account):
        return self.values.get((service, account))

    def set_password(self, service, account, value):
        self.values[service, account] = value

    def delete_password(self, service, account):
        self.values.pop((service, account), None)


def fake_vault():
    vault = module.SystemVault(enabled=False)
    vault.backend = MemoryKeyring()
    return vault


class SystemVaultTests(unittest.TestCase):
    def test_round_trip_expiration_and_corrupt_records(self):
        vault = fake_vault()
        with patch.object(module.time, 'time', return_value=1000000):
            vault.write('synthetic_session_12345')
            self.assertEqual(vault.read(), ('synthetic_session_12345', False))
        with patch.object(module.time, 'time', return_value=1000000 + 31 * 86400):
            self.assertEqual(vault.read(), (None, True))
        vault.backend.set_password(vault.SERVICE, vault.ACCOUNT, 'synthetic malformed JSON')
        self.assertEqual(vault.read(), (None, True))
        self.assertIsNone(vault.backend.get_password(vault.SERVICE, vault.ACCOUNT))

    def test_secret_tool_sends_session_only_via_stdin_and_never_relays_stderr(self):
        vault = module.SystemVault(enabled=False)
        vault.command = '/synthetic/secret-tool'
        values = []
        def run(arguments, **kwargs):
            self.assertNotIn('synthetic_session_12345', ' '.join(arguments))
            if arguments[1] == 'store':
                values.append(kwargs['input'])
            return subprocess.CompletedProcess(arguments, 0,
                values[-1] if arguments[1] == 'lookup' else b'', b'')
        import subprocess
        with patch.object(module.subprocess, 'run', side_effect=run):
            vault.write('synthetic_session_12345')
            self.assertEqual(vault.read(), ('synthetic_session_12345', False))
        with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 2, b'', b'synthetic_private_session_do_not_echo')):
            with self.assertRaises(module.VaultError) as result:
                vault.read()
            self.assertNotIn('synthetic_private', str(result.exception))

    def test_unavailable_storage_has_no_file_or_plaintext_fallback(self):
        vault = module.SystemVault(enabled=False)
        self.assertFalse(vault.supported)
        self.assertEqual(vault.read(), (None, False))
        with self.assertRaises(module.VaultError):
            vault.write('synthetic_session_12345')


class LocalServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "index.html").write_text("<h1>Shiori</h1>")
        self.server = module.create_server(root, vault=module.SystemVault(enabled=False))
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

    def test_opt_in_restore_disable_and_logout_without_returning_cookie(self):
        root = self.server.state.web_root
        vault = fake_vault()
        self.server.state = module.State(root, vault=vault)
        self.token = self.server.state.token
        self.request('POST', '/api/session', {'session': 'synthetic_session_12345'})
        self.assertEqual(vault.read(), (None, False))
        self.assertEqual(self.request('POST', '/api/remember', {'enabled': True})[0], 200)
        self.assertEqual(vault.read()[0], 'synthetic_session_12345')
        self.server.state = module.State(root, vault=vault)
        self.token = self.server.state.token
        status, data = self.request('GET', '/api/config')
        config = json.loads(data)
        self.assertTrue(config['loggedIn'] and config['rememberSession'])
        self.assertNotIn(b'synthetic_session', data)
        self.assertEqual(self.request('POST', '/api/remember', {'enabled': False})[0], 200)
        self.assertIsNone(vault.read()[0])
        self.assertIsNotNone(self.server.state.session)
        self.request('POST', '/api/remember', {'enabled': True})
        self.assertEqual(self.request('DELETE', '/api/session')[0], 200)
        self.assertIsNone(vault.read()[0])
        self.assertIsNone(self.server.state.session)

    def test_remember_control_requires_auth_origin_and_boolean_and_fails_safely(self):
        self.assertEqual(self.request('POST', '/api/remember', {'enabled': True})[0], 503)
        self.assertEqual(self.request('POST', '/api/remember', {'enabled': True}, authorized=False)[0], 403)
        self.assertEqual(self.request('POST', '/api/remember', {'enabled': True},
            headers={'Origin': 'https://evil.example'})[0], 403)
        for value in [1, 'true', None, {}, []]:
            self.assertEqual(self.request('POST', '/api/remember', {'enabled': value})[0], 400)

    def test_failed_persistence_is_reported_and_never_claims_saved_login(self):
        vault = fake_vault()
        self.server.state.vault = vault
        self.request('POST', '/api/remember', {'enabled': True})
        with patch.object(vault, 'write', side_effect=module.VaultError('synthetic failure')):
            status, data = self.request('POST', '/api/session', {'session': 'synthetic_session_12345'})
        result = json.loads(data)
        self.assertEqual(status, 200)
        self.assertTrue(result['loggedIn'] and result['storageError'])
        self.assertFalse(result['rememberSession'])
        self.assertIsNone(vault.read()[0])


if __name__ == "__main__": unittest.main()
