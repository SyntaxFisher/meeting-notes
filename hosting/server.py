#!/usr/bin/env python3
"""Serve app association and a generic fallback, without recording request URLs."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
ASSETS = {
    "/.well-known/apple-app-site-association": ("apple-app-site-association", "application/json"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/open.js": ("open.js", "text/javascript; charset=utf-8"),
}


class Handler(BaseHTTPRequestHandler):
    server_version = "MeetingNotesLinks"
    sys_version = ""

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.respond(body=True)

    def do_HEAD(self):
        self.respond(body=False)

    def respond(self, body):
        path = urlsplit(self.path).path
        association = path == "/.well-known/apple-app-site-association"
        if path in ASSETS:
            name, content_type = ASSETS[path]
            content = (ROOT / name).read_bytes()
            status = 200
        elif path == "/" or path.startswith("/meeting/"):
            content_type = "text/html; charset=utf-8"
            content = (ROOT / "index.html").read_bytes()
            status = 200
        elif path == "/robots.txt":
            content_type, content, status = "text/plain; charset=utf-8", b"User-agent: *\nDisallow: /\n", 200
        else:
            content_type, content, status = "text/plain; charset=utf-8", b"Not found.\n", 404
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "public, max-age=3600" if association else "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Robots-Tag", "noindex, nofollow, noarchive")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        self.end_headers()
        if body:
            self.wfile.write(content)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        pass


if __name__ == "__main__":
    Server(("127.0.0.1", 2597), Handler).serve_forever()
