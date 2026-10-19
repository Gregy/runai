#!/usr/bin/env python3
"""Host-side daemon serving container -> host requests over loopback HTTP.

Endpoints (all POST, HTTP Basic auth as user "container"):
  /open        form-encoded "url=<http(s) URL>"  -> opens it in the host browser
  /clipboard   raw request body (UTF-8)          -> copies it to the host clipboard,
               typed by Content-Type: text/plain (default) or text/html
  /clipboard/alternatives
               JSON {"text/html": "...", "text/plain": "..."} -> the same content
               in several formats at once, like a browser or spreadsheet copy:
               an email client pastes the HTML, a terminal pastes the text.
               Replies with X-Clipboard-Types listing the formats actually
               offered (fewer than requested if the host can't hold several).
  /            alias for /open (kept for older container images)

Binds to 127.0.0.1 on an OS-assigned port and requires HTTP Basic auth
(username "container", password from $HOST_BRIDGE_PASS). Prints the
chosen port to stdout on startup and writes it to argv[1] if given.

The clipboard is deliberately WRITE-ONLY: there is no endpoint to read the
host clipboard back, because it routinely holds passwords and other secrets
that the container has no business being able to pull out.

Offering several formats at once needs a process that owns the selection and
answers each paste request itself; wl-copy, xclip and xsel only ever offer a
single type. `host-bridge.py --hold-clipboard` is that process: it uses GTK 4
(PyGObject) over X11/XWayland and exits as soon as anything else takes the
clipboard. Without GTK 4 the bridge falls back to offering just the HTML.
"""
import base64
import hmac
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

USER = "container"
EXPECTED = None  # "Basic ..." header value, set in main()

# Generous enough for HTML tables with inline styles; small enough that a
# runaway `cat big.log | host-clipboard` can't balloon the daemon.
MAX_CLIPBOARD_BYTES = 1024 * 1024
MAX_OPEN_BYTES = 64 * 1024

# Formats the container may put on the clipboard, in the order a single-type
# fallback prefers them (HTML is the reason to send alternatives at all).
CLIPBOARD_TYPES = ("text/html", "text/plain")

# Python interpreters to try for the --hold-clipboard helper: ours first, then
# the system one, which is where distro PyGObject lives if we run from a venv.
HOLDER_PYTHONS = (sys.executable, "/usr/bin/python3")
HOLDER_READY_TIMEOUT = 5


def clipboard_writers(mime):
    """Candidate single-type host clipboard writers for mime, most specific
    first. Each entry is (required env var or None, argv)."""
    if mime == "text/plain":
        # No -target for xclip: its default serves UTF8_STRING, STRING, TEXT
        # etc., whereas "-target text/plain" would offer only that one atom.
        wl = ["wl-copy", "--type", "text/plain"]
        x = [["xclip", "-selection", "clipboard", "-in"],
             ["xsel", "--input", "--clipboard"]]
    else:
        wl = ["wl-copy", "--type", mime]
        x = [["xclip", "-selection", "clipboard", "-target", mime, "-in"]]
    return ([("WAYLAND_DISPLAY", wl)] + [("DISPLAY", argv) for argv in x]
            + [(None, wl)] + [(None, argv) for argv in x])


def clipboard_writer(mime):
    """Return the argv of an available host clipboard writer, or None."""
    for required_env, argv in clipboard_writers(mime):
        if required_env and not os.environ.get(required_env):
            continue
        if shutil.which(argv[0]):
            return argv
    return None


def with_charset(html):
    """Declare UTF-8 unless the HTML already declares a charset; some
    browsers otherwise guess the encoding of pasted HTML and get it wrong."""
    if "charset" in html[:1024].lower():
        return html
    return '<meta charset="utf-8">' + html


class ClipboardError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def write_single(mime, data):
    """Put data on the host clipboard as the single type mime."""
    argv = clipboard_writer(mime)
    if argv is None:
        tools = ("wl-clipboard (Wayland) or xclip/xsel (X11)" if mime == "text/plain"
                 else "wl-clipboard (Wayland) or xclip (X11)")
        raise ClipboardError(503, f"no host clipboard tool for {mime} found; install {tools} on the host")
    # wl-copy, xclip and xsel all fork a background child to hold the
    # selection, and that child inherits our stderr. So stderr must be a
    # real file, not a pipe: with a pipe, communicate() would sit waiting
    # for an EOF the holder never sends and we would hit the timeout below
    # even though the writer took the data and exited immediately.
    with tempfile.TemporaryFile() as err:
        try:
            subprocess.run(
                argv,
                input=data,
                stdout=subprocess.DEVNULL,
                stderr=err,
                timeout=5,
                check=True,
            )
        except subprocess.TimeoutExpired:
            raise ClipboardError(504, f"{argv[0]} timed out")
        except subprocess.CalledProcessError:
            err.seek(0)
            detail = err.read().decode("utf-8", errors="replace").strip()
            raise ClipboardError(502, f"{argv[0]} failed: {detail}")
        except OSError as e:
            raise ClipboardError(502, f"failed to run {argv[0]}: {e}")


def write_multi(contents):
    """Hand {mime: bytes} to a --hold-clipboard helper. Returns False if no
    helper can run here (no X display, no GTK 4), so the caller can fall back."""
    if not os.environ.get("DISPLAY"):
        return False
    payload = json.dumps({m: d.decode("utf-8") for m, d in contents.items()}).encode()
    # Force X11: a windowless Wayland client is not allowed to take the
    # selection, while an X11 one is, and XWayland passes it on to
    # Wayland-native apps.
    env = dict(os.environ, GDK_BACKEND="x11")
    for python in dict.fromkeys(p for p in HOLDER_PYTHONS if p and shutil.which(p)):
        # stderr goes to a file for the same reason as in write_single; the
        # helper reports readiness on its stdout and then detaches from it.
        with tempfile.TemporaryFile() as err:
            try:
                proc = subprocess.Popen(
                    [python, os.path.abspath(__file__), "--hold-clipboard"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=err,
                    env=env,
                    start_new_session=True,
                )
            except OSError:
                continue
            try:
                proc.stdin.write(payload)
                proc.stdin.close()
                ready, _, _ = select.select([proc.stdout], [], [], HOLDER_READY_TIMEOUT)
                status = proc.stdout.readline().decode(errors="replace").strip() if ready else ""
            except OSError as e:
                status = f"error: {e}"
            finally:
                proc.stdout.close()
            if status != "ok":
                # The helper forks; kill its whole group, not just the parent.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.wait()
            if status == "ok":
                return True
            if status.startswith("unavailable"):
                continue
            err.seek(0)
            detail = status or err.read().decode("utf-8", errors="replace").strip() or "timed out"
            raise ClipboardError(502, f"clipboard holder failed: {detail}")
    return False


def hold_clipboard():
    """--hold-clipboard: own the clipboard with every format from the JSON
    {mime: text} on stdin, until something else takes it over.

    Prints one status line to stdout ("ok", "unavailable: ...", or
    "error: ...") and, once it owns the clipboard, detaches from stdout and
    stderr so the bridge is not tied to it."""
    contents = json.load(sys.stdin)
    # Fork so the bridge can reap the process it started right away; the
    # child, which holds the clipboard, then belongs to init and not to it.
    if os.fork():
        os._exit(0)
    try:
        import gi
        gi.require_version("Gdk", "4.0")
        gi.require_version("Gtk", "4.0")
        from gi.repository import Gdk, GLib, Gtk
    except (ImportError, ValueError) as e:
        print(f"unavailable: GTK 4 for Python (PyGObject) not found: {e}", flush=True)
        sys.exit(3)
    if not Gtk.init_check():
        print("unavailable: cannot open the X display", flush=True)
        sys.exit(3)
    clipboard = Gdk.Display.get_default().get_clipboard()

    providers = []
    for mime, text in contents.items():
        data = GLib.Bytes.new(text.encode("utf-8"))
        # GTK maps text/plain;charset=utf-8 to UTF8_STRING, STRING, TEXT etc.
        # for X clients; plain "text/plain" is for apps that ask for exactly that.
        for target in (["text/plain;charset=utf-8", "text/plain"] if mime == "text/plain" else [mime]):
            providers.append(Gdk.ContentProvider.new_for_bytes(target, data))
    if not clipboard.set_content(Gdk.ContentProvider.new_union(providers)) or not clipboard.is_local():
        print("error: could not take ownership of the clipboard", flush=True)
        sys.exit(1)

    loop = GLib.MainLoop()
    clipboard.connect("changed", lambda cb: cb.is_local() or loop.quit())
    print("ok", flush=True)
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    loop.run()


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
        elif route == "/clipboard/alternatives":
            self.handle_clipboard_alternatives()
        else:
            self.reply(404, f"unknown endpoint: {route}\n")

    # ── endpoints ────────────────────────────────────────────────────
    def handle_open(self):
        body = self.read_body(MAX_OPEN_BYTES)
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
        mime = (self.headers.get("Content-Type") or "text/plain").split(";")[0].strip().lower()
        if mime not in CLIPBOARD_TYPES:
            self.reply(415, f"unsupported clipboard type {mime!r}; use one of {', '.join(CLIPBOARD_TYPES)}\n")
            return
        self.copy({mime: body})

    def handle_clipboard_alternatives(self):
        body = self.read_body(MAX_CLIPBOARD_BYTES)
        if body is None:
            return
        try:
            contents = json.loads(body)
        except ValueError:
            self.reply(400, "body must be a JSON object {mime: text}\n")
            return
        if (not isinstance(contents, dict) or not contents
                or not all(isinstance(v, str) for v in contents.values())):
            self.reply(400, "body must be a non-empty JSON object {mime: text}\n")
            return
        unknown = sorted(set(contents) - set(CLIPBOARD_TYPES))
        if unknown:
            self.reply(415, f"unsupported clipboard type(s) {', '.join(unknown)}; use {', '.join(CLIPBOARD_TYPES)}\n")
            return
        self.copy({m: v.encode("utf-8") for m, v in contents.items()})

    def copy(self, contents):
        """Put {mime: bytes} on the host clipboard, all formats if possible."""
        if "text/html" in contents:
            contents["text/html"] = with_charset(contents["text/html"].decode("utf-8", errors="replace")).encode()
        offered = [m for m in CLIPBOARD_TYPES if m in contents]
        try:
            if len(offered) == 1 or not write_multi(contents):
                offered = offered[:1]
                write_single(offered[0], contents[offered[0]])
        except ClipboardError as e:
            self.reply(e.code, f"{e}\n")
            return
        # Never log or echo the payload itself.
        self.send_response(204)
        self.send_header("X-Clipboard-Types", ", ".join(offered))
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
    global EXPECTED
    password = os.environ.get("HOST_BRIDGE_PASS")
    if not password:
        print("HOST_BRIDGE_PASS not set", file=sys.stderr)
        sys.exit(1)
    EXPECTED = "Basic " + base64.b64encode(f"{USER}:{password}".encode()).decode()

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
    if sys.argv[1:] == ["--hold-clipboard"]:
        hold_clipboard()
    else:
        main()
