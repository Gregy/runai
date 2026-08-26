#!/usr/bin/env python3
"""Host-side daemon serving container -> host requests over loopback HTTP.

Endpoints (all POST, HTTP Basic auth as user "container"):
  /open       form-encoded "url=<http(s) URL>"  -> opens it in the host browser
  /clipboard  raw request body (UTF-8 text)     -> copies it to the host clipboard
  /           alias for /open (kept for older container images)

Binds to 127.0.0.1 on an OS-assigned port and requires HTTP Basic auth
(username "container", password from $HOST_BRIDGE_PASS). Prints the
chosen port to stdout on startup and writes it to argv[1] if given.

The clipboard is deliberately WRITE-ONLY: there is no endpoint to read the
host clipboard back, because it routinely holds passwords and other secrets
that the container has no business being able to pull out.
"""
import base64
import hmac
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

USER = "container"
PASSWORD = os.environ.get("HOST_BRIDGE_PASS")
if not PASSWORD:
    print("HOST_BRIDGE_PASS not set", file=sys.stderr)
    sys.exit(1)
EXPECTED = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()

# Generous enough for OAuth codes, tokens and short snippets; small enough that
# a runaway `cat big.log | host-clipboard` can't balloon the daemon.
MAX_CLIPBOARD_BYTES = 64 * 1024

# Candidate host clipboard writers, most specific first. Each entry is
# (required env var or None, argv).
CLIPBOARD_WRITERS = (
    ("WAYLAND_DISPLAY", ["wl-copy", "--type", "text/plain"]),
    ("DISPLAY", ["xclip", "-selection", "clipboard", "-in"]),
    ("DISPLAY", ["xsel", "--input", "--clipboard"]),
    (None, ["wl-copy", "--type", "text/plain"]),
    (None, ["xclip", "-selection", "clipboard", "-in"]),
    (None, ["xsel", "--input", "--clipboard"]),
)


def clipboard_writer():
    """Return the argv of an available host clipboard writer, or None."""
    for required_env, argv in CLIPBOARD_WRITERS:
        if required_env and not os.environ.get(required_env):
            continue
        if shutil.which(argv[0]):
            return argv
    return None


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not hmac.compare_digest(self.headers.get("Authorization", ""), EXPECTED):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="host-bridge"')
            self.end_headers()
            return

        route = urllib.parse.urlparse(self.path).path.rstrip("/") or "/open"
        if route == "/":
            route = "/open"

        if route == "/open":
            self.handle_open()
        elif route == "/clipboard":
            self.handle_clipboard()
        else:
            self.reply(404, f"unknown endpoint: {route}\n")

    # ── endpoints ────────────────────────────────────────────────────
    def handle_open(self):
        body = self.read_body(MAX_CLIPBOARD_BYTES)
        if body is None:
            return
        url = (urllib.parse.parse_qs(body.decode("utf-8", errors="replace")).get("url") or [""])[0]
        if not (url.startswith("http://") or url.startswith("https://")):
            self.reply(400, "only http/https URLs are accepted\n")
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
            print("host-bridge: xdg-open not installed", file=sys.stderr)
        except OSError as e:
            print(f"host-bridge: failed to launch xdg-open: {e}", file=sys.stderr)

    def handle_clipboard(self):
        body = self.read_body(MAX_CLIPBOARD_BYTES)
        if body is None:
            return
        argv = clipboard_writer()
        if argv is None:
            self.reply(
                503,
                "no host clipboard tool found; install wl-clipboard (Wayland) "
                "or xclip/xsel (X11) on the host\n",
            )
            return
        # wl-copy, xclip and xsel all fork a background child to hold the
        # selection, and that child inherits our stderr. So stderr must be a
        # real file, not a pipe: with a pipe, communicate() would sit waiting
        # for an EOF the holder never sends and we would hit the timeout below
        # even though the writer took the data and exited immediately.
        with tempfile.TemporaryFile() as err:
            try:
                subprocess.run(
                    argv,
                    input=body,
                    stdout=subprocess.DEVNULL,
                    stderr=err,
                    timeout=5,
                    check=True,
                )
            except subprocess.TimeoutExpired:
                self.reply(504, f"{argv[0]} timed out\n")
                return
            except subprocess.CalledProcessError:
                err.seek(0)
                detail = err.read().decode("utf-8", errors="replace").strip()
                self.reply(502, f"{argv[0]} failed: {detail}\n")
                return
            except OSError as e:
                self.reply(502, f"failed to run {argv[0]}: {e}\n")
                return
        # Never log or echo the payload itself.
        self.send_response(204)
        self.end_headers()

    # ── helpers ──────────────────────────────────────────────────────
    def read_body(self, limit):
        """Read the request body, or reply with an error and return None."""
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.reply(400, "bad Content-Length\n")
            return None
        if length > limit:
            self.reply(413, f"body too large (limit {limit} bytes)\n")
            return None
        return self.rfile.read(length)

    def reply(self, code, message):
        payload = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

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
