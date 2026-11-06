#!/usr/bin/env python3
"""Local-only Flutter Web host + narrowly scoped Pixiv transport. Python 3.10+."""
from __future__ import annotations

import argparse
import http.client
import json
import mimetypes
import re
import secrets
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a Pixiv session to an unexpected redirect target.
        return None


class State:
    def __init__(self, web_root: Path):
        self.web_root = web_root.resolve()
        self.token = secrets.token_urlsafe(32)
        self.session: str | None = None
        self.pair_token: str | None = None
        self.pair_deadline = 0.0
        self.lock = threading.Lock()


PAIR_HTML = b'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Shiori Bridge</title><style>body{font:17px/1.9 system-ui;background:#f6f7f3;color:#243b36;max-width:640px;margin:12vh auto;padding:32px}button{padding:14px 22px;background:#1f6a53;color:white;border:0;border-radius:8px;font-size:17px}</style><h1>Shiori Bridge</h1><p>Install the bundled Shiori Bridge extension, then refresh this page. Click the connect button below and approve the connection on the extension page. Sign in on the official Pixiv website.</p><p>The session is sent only to this local app and held in memory. This pairing expires in five minutes. Do not share this page URL.</p></html>'''


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

    def _respond(self, status, data=b"", mime="application/json", cors=None):
        if not isinstance(data, bytes):
            data = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
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
            self._respond(200, {"token": self.state.token, "loggedIn": self.state.session is not None}); return
        if url.path.startswith("/api/"):
            if not self._authorized():
                self._respond(403); return
            if url.path == "/api/session":
                self._respond(200, {"loggedIn": self.state.session is not None}); return
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
        request = urllib.request.Request("https://www.pixiv.net" + path, headers=headers)
        opener = urllib.request.build_opener(NoRedirect())
        try:
            with opener.open(request, timeout=25) as result:
                data = result.read(MAX_RESPONSE + 1)
                if len(data) > MAX_RESPONSE:
                    self._respond(502, {"error": True, "message": "response too large"}); return
                self._respond(result.status, data)
        except urllib.error.HTTPError as error:
            # Do not relay upstream HTML, Set-Cookie, redirect targets, or headers.
            self._respond(error.code if error.code in {401, 403, 404, 429} else 502,
                          {"error": True, "message": "upstream rejected request"})
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
                self.state.session = session
                self.state.pair_token = None  # A pairing token can be consumed only once.
            self._respond(200, {"ok": True}, cors=cors); return
        if not self._authorized():
            self._respond(403); return
        if self.path == "/api/login":
            with self.state.lock:
                self.state.session = None
                self.state.pair_token = secrets.token_urlsafe(32)
                self.state.pair_deadline = time.monotonic() + 300
                url = f"http://127.0.0.1:{self.server.server_port}/pair#{self.state.pair_token}"
            self._respond(200, {"url": url}); return
        if self.path == "/api/session":
            try:
                data = self._json_body()
                session = data.get("session") if isinstance(data, dict) else None
                if not isinstance(session, str) or not SESSION.fullmatch(session): raise ValueError()
                with self.state.lock: self.state.session = session
                self._respond(200, {"ok": True})
            except (ValueError, TimeoutError, OSError): self._respond(400)
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
            if self.path == "/api/session": self.state.session = None
        self._respond(200, {"ok": True})


def create_server(web_root: Path, port=0):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.state = State(web_root)
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
    print(f"Shiori is running locally: {url}\nPress Ctrl+C to stop and clear the session.", flush=True)
    if not args.no_browser: webbrowser.open(url)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally:
        server.state.session = None
        server.state.pair_token = None
        server.server_close()


if __name__ == "__main__": main()
