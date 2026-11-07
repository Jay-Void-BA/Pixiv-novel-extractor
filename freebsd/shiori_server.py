#!/usr/bin/env python3
"""Local-only Flutter Web host + narrowly scoped Pixiv transport. Python 3.10+."""
from __future__ import annotations

import argparse
import http.client
import json
import os
import mimetypes
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 2048
MAX_RESPONSE = 32 * 1024 * 1024
PIXIV_PATH = re.compile(r"/ajax/novel/(?:[1-9]\d*|series/[1-9]\d*(?:/content_titles)?)$")
SESSION = re.compile(r"[A-Za-z0-9_%.-]{8,512}$")
EXTENSION_ORIGIN = re.compile(r"(?:chrome|moz)-extension://[A-Za-z0-9-]+$")


class VaultError(Exception):
    """Safe error: never carry backend output or credential values."""


class SystemVault:
    """Optional OS keyring, never a plaintext file or browser storage fallback."""
    SERVICE = 'io.github.jayvoid.shiori.local-web'
    ACCOUNT = 'pixiv-session-v1'
    MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000

    def __init__(self, *, enabled=True):
        self.command = None
        self.backend = None
        if not enabled:
            return
        if sys.platform.startswith(('linux', 'freebsd')) and os.environ.get('DBUS_SESSION_BUS_ADDRESS'):
            self.command = shutil.which('secret-tool')
        if self.command:
            return
        # Select known OS backends explicitly; never load keyrings.alt/plaintext
        # or an automatically selected third-party/chained backend.
        try:
            if sys.platform == 'win32':
                from keyring.backends.Windows import WinVaultKeyring
                backend = WinVaultKeyring()
            elif sys.platform == 'darwin':
                from keyring.backends.macOS import Keyring
                backend = Keyring()
            else:
                from keyring.backends.SecretService import Keyring
                backend = Keyring()
            if backend.priority > 0:
                self.backend = backend
        except Exception:
            pass

    @property
    def supported(self):
        return self.command is not None or self.backend is not None

    def _secret_tool(self, action, value=None):
        arguments = [self.command, action]
        if action == 'store':
            arguments.append('--label=Shiori Pixiv session')
        arguments.extend(['application', self.SERVICE, 'account', self.ACCOUNT])
        try:
            result = subprocess.run(arguments, input=value.encode() if value is not None else None,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
            if result.returncode == 1 and not result.stderr and action in {'lookup', 'clear'}:
                return None
            if result.returncode or len(result.stdout) > 4096:
                raise VaultError()
            return result.stdout.decode('utf-8').rstrip('\n') if action == 'lookup' else None
        except Exception:
            raise VaultError('System secure storage unavailable') from None

    def _read_value(self):
        if self.command:
            return self._secret_tool('lookup')
        return self.backend.get_password(self.SERVICE, self.ACCOUNT)

    def _write_value(self, value):
        if self.command:
            self._secret_tool('store', value)
        else:
            self.backend.set_password(self.SERVICE, self.ACCOUNT, value)

    def _delete_value(self):
        if self.command:
            self._secret_tool('clear')
        elif self.backend.get_password(self.SERVICE, self.ACCOUNT) is not None:
            self.backend.delete_password(self.SERVICE, self.ACCOUNT)

    def read(self):
        if not self.supported:
            return None, False
        try:
            value = self._read_value()
        except Exception:
            raise VaultError('System secure storage unavailable') from None
        if value is None:
            return None, False
        try:
            if not isinstance(value, str) or len(value) > 4096:
                raise ValueError()
            data = json.loads(value)
            now = int(time.time() * 1000)
            if (not isinstance(data, dict) or type(data.get('version')) is not int or data['version'] != 1
                    or not isinstance(data.get('session'), str) or not SESSION.fullmatch(data['session'])
                    or type(data.get('savedAt')) is not int or type(data.get('expiresAt')) is not int
                    or not 0 < data['savedAt'] <= now < data['expiresAt']
                    or data['expiresAt'] != data['savedAt'] + self.MAX_AGE_MS):
                raise ValueError()
            return data['session'], False
        except (ValueError, TypeError):
            self.delete()
            return None, True

    def write(self, session):
        if not self.supported or not SESSION.fullmatch(session):
            raise VaultError('System secure storage unavailable')
        saved = int(time.time() * 1000)
        value = json.dumps({'version': 1, 'session': session, 'savedAt': saved,
                           'expiresAt': saved + self.MAX_AGE_MS})
        try:
            self._write_value(value)
            if self._read_value() != value:
                raise VaultError()
        except Exception:
            try:
                self._delete_value()
            except Exception:
                pass
            raise VaultError('System secure storage unavailable') from None

    def delete(self):
        if not self.supported:
            return
        try:
            self._delete_value()
            if self._read_value() is not None:
                raise VaultError()
        except Exception:
            raise VaultError('Unable to delete saved session') from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a Pixiv session to an unexpected redirect target.
        return None


class State:
    def __init__(self, web_root: Path, vault=None):
        self.web_root = web_root.resolve()
        self.token = secrets.token_urlsafe(32)
        self.session: str | None = None
        self.session_generation = 0
        self.pair_token: str | None = None
        self.pair_deadline = 0.0
        self.lock = threading.RLock()
        self.vault = vault if vault is not None else SystemVault()
        self.remember_session = False
        self.storage_error = False
        self.startup_notice = None
        try:
            self.session, discarded = self.vault.read()
            self.remember_session = self.session is not None
            if self.session:
                self.startup_notice = '已从本机系统密钥库恢复会话，将在请求时验证有效性。'
            elif discarded:
                self.startup_notice = '保存的会话已过期或无法验证，已清除，请重新登录。'
        except VaultError:
            self.startup_notice = '无法读取系统密钥库。请解锁密钥库；当前仅使用内存会话。'

    def status(self):
        with self.lock:
            return {'loggedIn': self.session is not None, 'rememberSession': self.remember_session,
                    'storageError': self.storage_error}

    def install_session(self, value):
        with self.lock:
            self.session = value
            self.session_generation += 1
            self.storage_error = False
            if self.remember_session:
                try:
                    self.vault.write(value)
                except VaultError:
                    self.remember_session = False
                    self.storage_error = True

    def clear_session(self, *, forget=False):
        with self.lock:
            self.session = None
            self.session_generation += 1
            self.storage_error = False
            if forget:
                self.remember_session = False
            self.vault.delete()

    def set_remember(self, enabled):
        with self.lock:
            if not self.vault.supported:
                raise VaultError('System secure storage unavailable')
            if enabled and self.session:
                self.vault.write(self.session)
            if not enabled:
                self.vault.delete()
            self.remember_session = enabled
            self.storage_error = False


PAIR_HTML = b'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Shiori Bridge</title><style>body{font:17px/1.9 system-ui;background:#f6f7f3;color:#243b36;max-width:640px;margin:12vh auto;padding:32px}button{padding:14px 22px;background:#1f6a53;color:white;border:0;border-radius:8px;font-size:17px}</style><h1>Shiori Bridge</h1><p>Install the bundled Shiori Bridge extension, then refresh this page. Click the connect button below and approve the connection on the extension page. Sign in on the official Pixiv website.</p><p>The session is sent only to this local app. Secure login saving is controlled by the app settings. This pairing expires in five minutes. Do not share this page URL.</p></html>'''


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ShioriLocal/1.0"

    @property
    def state(self) -> State:
        return self.server.state

    def log_message(self, format, *args):
        pass  # No URL, token, cookie, or novel-content logging.

    def _origin(self):
        host = self.headers.get("Host", "")
        valid_hosts = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        if host not in valid_hosts:
            return False, None
        origin = self.headers.get("Origin")
        if origin is None:
            return self.headers.get("Sec-Fetch-Site", "none") in {"none", "same-origin"}, None
        if origin == f"http://{host}":
            return True, None
        if self.path == "/session" and EXTENSION_ORIGIN.fullmatch(origin):
            return True, origin
        return False, None

    def _respond(self, status, data=b"", mime="application/json", cors=None, retry_after=None):
        if not isinstance(data, bytes):
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        # Only this narrowly validated upstream header is relayed, never cookies or redirects.
        if retry_after and re.fullmatch(
                r"(?:\d{1,10}|[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT)", retry_after):
            self.send_header("Retry-After", retry_after)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin-allow-popups")
        if cors:
            self.send_header("Access-Control-Allow-Origin", cors)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
            self.send_header("Access-Control-Allow-Private-Network", "true")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _authorized(self):
        return secrets.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.state.token)

    def _json_body(self):
        # Transfer-Encoding is deliberately unsupported. Require a bounded body.
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("unsupported encoding")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= MAX_BODY:
            raise ValueError("invalid length")
        self.connection.settimeout(5)
        data = self.rfile.read(length)
        if len(data) != length:
            raise ValueError("truncated body")
        return json.loads(data)

    def do_OPTIONS(self):
        allowed, cors = self._origin()
        if not allowed or self.path != "/session":
            self._respond(403); return
        self._respond(204, cors=cors)

    def do_GET(self):
        allowed, _ = self._origin()
        if not allowed:
            self._respond(403); return
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/api/config":
            self._respond(200, {"token": self.state.token, **self.state.status(),
                "supportsSessionStorage": self.state.vault.supported,
                "startupNotice": self.state.startup_notice}); return
        if url.path.startswith("/api/"):
            if not self._authorized():
                self._respond(403); return
            if url.path == "/api/session":
                self._respond(200, self.state.status()); return
            if url.path == "/api/pixiv":
                paths = urllib.parse.parse_qs(url.query).get("path", [])
                if len(paths) != 1 or not PIXIV_PATH.fullmatch(paths[0]):
                    self._respond(400); return
                self._pixiv(paths[0]); return
            self._respond(404); return
        if url.path == "/pair":
            self._respond(200, PAIR_HTML, "text/html; charset=utf-8"); return
        try:
            decoded = urllib.parse.unquote(url.path)
            path = (self.state.web_root / decoded.lstrip("/")).resolve()
            if not path.is_relative_to(self.state.web_root):
                self._respond(403); return
            if path.is_dir(): path = path / "index.html"
            if not path.is_file():
                self._respond(404); return
            data = path.read_bytes()
            mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            if path.suffix == ".wasm": mime = "application/wasm"
            self._respond(200, data, mime)
        except (OSError, ValueError):
            self._respond(404)

    def _pixiv(self, path):
        headers = {"Accept": "application/json", "Referer": "https://www.pixiv.net/",
                   "User-Agent": "Mozilla/5.0 Shiori/1.0"}
        with self.state.lock:
            if self.state.session: headers["Cookie"] = "PHPSESSID=" + self.state.session
            generation = self.state.session_generation
        request = urllib.request.Request("https://www.pixiv.net" + path, headers=headers)
        opener = urllib.request.build_opener(NoRedirect())
        try:
            with opener.open(request, timeout=25) as result:
                data = result.read(MAX_RESPONSE + 1)
                if len(data) > MAX_RESPONSE:
                    self._respond(502, {"error": True, "message": "response too large"}); return
                with self.state.lock:
                    stale = generation != self.state.session_generation
                if stale:
                    self._respond(409, {"error": True, "message": "session changed"}); return
                self._respond(result.status, data)
        except urllib.error.HTTPError as error:
            # Do not relay upstream HTML, Set-Cookie, redirect targets, or headers.
            self._respond(error.code if error.code in {401, 403, 404, 429} else 502,
                          {"error": True, "message": "upstream rejected request"},
                          retry_after=error.headers.get("Retry-After") if error.headers else None)
        except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException):
            self._respond(502, {"error": True, "message": "upstream unavailable"})

    def do_POST(self):
        allowed, cors = self._origin()
        if not allowed:
            self._respond(403); return
        if self.path == "/session":
            with self.state.lock:
                token = self.state.pair_token
                valid = token and time.monotonic() < self.state.pair_deadline and secrets.compare_digest(
                    self.headers.get("Authorization", ""), "Bearer " + token)
                if not valid:
                    self._respond(403, cors=cors); return
                try:
                    data = self._json_body()
                    session = data.get("session") if isinstance(data, dict) else None
                    if not isinstance(session, str) or not SESSION.fullmatch(session): raise ValueError()
                except (ValueError, TimeoutError, OSError):
                    self._respond(400, cors=cors); return
                self.state.install_session(session)
                self.state.pair_token = None  # A pairing token can be consumed only once.
            self._respond(200, {"ok": True, **self.state.status()}, cors=cors); return
        if not self._authorized():
            self._respond(403); return
        if self.path == "/api/login":
            try:
                self.state.clear_session()
            except VaultError:
                self._respond(503, {"error": True, "message": "secure storage unavailable"}); return
            with self.state.lock:
                self.state.pair_token = secrets.token_urlsafe(32)
                self.state.pair_deadline = time.monotonic() + 300
                url = f"http://127.0.0.1:{self.server.server_port}/pair#{self.state.pair_token}"
            self._respond(200, {"url": url}); return
        if self.path == "/api/session":
            try:
                data = self._json_body()
                session = data.get("session") if isinstance(data, dict) else None
                if not isinstance(session, str) or not SESSION.fullmatch(session): raise ValueError()
                self.state.install_session(session)
                self._respond(200, {"ok": True, **self.state.status()})
            except (ValueError, TimeoutError, OSError): self._respond(400)
            return
        if self.path == '/api/remember':
            try:
                data = self._json_body()
                enabled = data.get('enabled') if isinstance(data, dict) else None
                if type(enabled) is not bool:
                    raise ValueError()
                self.state.set_remember(enabled)
                self._respond(200, self.state.status())
            except (ValueError, TimeoutError, OSError):
                self._respond(400)
            except VaultError:
                self._respond(503, {'error': True, 'message': 'secure storage unavailable'})
            return
        self._respond(404)

    def do_DELETE(self):
        allowed, _ = self._origin()
        if not allowed or not self._authorized():
            self._respond(403); return
        if self.path not in {"/api/login", "/api/session"}:
            self._respond(404); return
        with self.state.lock:
            self.state.pair_token = None
        if self.path == "/api/session":
            try:
                self.state.clear_session(forget=True)
            except VaultError:
                self._respond(503, {'error': True, 'message': 'unable to delete saved session'}); return
        self._respond(200, {"ok": True})


def create_server(web_root: Path, port=0, *, vault=None):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.state = State(web_root, vault=vault)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", type=Path, default=Path(__file__).parent / "web")
    parser.add_argument("--port", type=int, default=0, help="0 selects a free local port")
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    if not (args.web_root / "index.html").is_file():
        parser.error("Web build missing: use the Release bundle, or pass --web-root build/web")
    server = create_server(args.web_root, args.port)
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"Shiori is running locally: {url}\nPress Ctrl+C to stop. Log out in the app to remove saved login.", flush=True)
    if not args.no_browser: webbrowser.open(url)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally:
        server.state.session = None
        server.state.pair_token = None
        server.server_close()


if __name__ == "__main__": main()
