#!/usr/bin/env python3
"""Host-side daemon that opens URLs in the host browser via xdg-open.

Binds to 127.0.0.1 on an OS-assigned port and requires HTTP Basic auth
(username "container", password from $HOST_BROWSER_PASS). Prints the
chosen port to stdout on startup and writes it to argv[1] if given.
"""
import base64
import hmac
import os
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

USER = "container"
PASSWORD = os.environ.get("HOST_BROWSER_PASS")
if not PASSWORD:
    print("HOST_BROWSER_PASS not set", file=sys.stderr)
    sys.exit(1)
EXPECTED = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), EXPECTED):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="host-browser"')
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        url = (urllib.parse.parse_qs(body).get("url") or [""])[0]
        if not (url.startswith("http://") or url.startswith("https://")):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"only http/https URLs are accepted\n")
            return
        self.send_response(204)
        self.end_headers()
        try:
            subprocess.Popen(
                ["xdg-open", url],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except FileNotFoundError:
            print("host-browser-opener: xdg-open not installed", file=sys.stderr)
        except OSError as e:
            print(f"host-browser-opener: failed to launch xdg-open: {e}", file=sys.stderr)

    def log_message(self, *args, **kwargs):
        pass


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            f.write(str(port))
    print(port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
