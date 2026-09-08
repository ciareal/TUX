#!/usr/bin/env python3
"""Start SuperTuxKart. Double-click this file, or run it from a terminal.

It serves this folder over HTTP. Open the printed address in your browser.

A server is needed because the engine is compiled with threads, so the browser
only grants it SharedArrayBuffer on a page that is *cross-origin isolated*.
That takes two response headers, which a file:// URL can never carry:

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp

Python's own http.server does not send them, so opening the page through it
gives a runtime that never starts. This adds them, serves the right MIME type
for .wasm, and handles requests on threads so the game's worker threads can
fetch alongside the main thread.

    python3 serve.py            # http://localhost:8000/
    python3 serve.py 9000       # a specific port
"""

import argparse
import functools
import os
import sys
from http import server

HERE = os.path.dirname(os.path.abspath(__file__))


class Handler(server.SimpleHTTPRequestHandler):
    extensions_map = {
        **server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".json": "application/json",
        ".manifest": "text/plain",
        # The bundle parts are named data_low.tar.gz.00 and friends. They go out
        # as opaque bytes on purpose: labelling them gzip would make the browser
        # inflate them on the way in, and the launcher does that itself.
        ".data": "application/octet-stream",
    }

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        # On everything, not just the HTML. The asset parts keep the same names
        # from build to build, so without this a browser is free to reuse an
        # older copy from its own cache and never ask whether it changed, which
        # silently pins the game to a stale bundle. "no-cache" still lets it
        # store them; it just has to revalidate, and unchanged files come back
        # as a cheap 304.
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        if not os.environ.get("STK_QUIET"):
            super().log_message(fmt, *args)


class Server(server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def describe_bundle(root):
    """Identify the asset bundle being served, so the console and the page can
    be compared. If they disagree, the browser is holding a stale copy."""
    manifest = os.path.join(root, "game", "data_low.tar.gz.manifest")
    try:
        with open(manifest) as fh:
            total = int(fh.readline().strip())
    except (OSError, ValueError):
        return "asset bundle: none found"
    return "asset bundle: {:,} bytes".format(total)


def wait_for_exit(message, code):
    """Keep the console window up when double-clicked, so errors are readable."""
    print(message, file=sys.stderr)
    try:
        if sys.stdin and sys.stdin.isatty():
            input("\nPress Enter to close this window.")
    except (EOFError, KeyboardInterrupt):
        pass
    sys.exit(code)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("port", nargs="?", type=int, default=8000)
    parser.add_argument("--dir", default=HERE,
                        help="folder to serve (defaults to this file's folder)")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="address to bind (use 0.0.0.0 to allow other machines)")
    args = parser.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        wait_for_exit("Not a folder: %s" % root, 1)

    if not os.path.isfile(os.path.join(root, "index.html")):
        wait_for_exit(
            "There is no index.html in %s.\n"
            "Run this from inside the game folder." % root, 1)

    if not os.path.isfile(os.path.join(root, "game", "supertuxkart.wasm")):
        print("Warning: game/supertuxkart.wasm is missing, so the page will",
              file=sys.stderr)
        print("report the game as not built. If you downloaded a ZIP from",
              file=sys.stderr)
        print("GitHub, the large files may not have come with it; use git",
              file=sys.stderr)
        print("clone instead. See README.md.\n", file=sys.stderr)

    # Step forward if the port is busy, so a stale server does not block a restart.
    handler = functools.partial(Handler, directory=root)
    httpd = None
    for port in range(args.port, args.port + 25):
        try:
            httpd = Server((args.bind, port), handler)
            break
        except OSError:
            continue
    if httpd is None:
        wait_for_exit(
            "Could not open a port between %d and %d.\n"
            "Something else is using them." % (args.port, args.port + 24), 1)

    port = httpd.server_address[1]
    host = "localhost" if args.bind in ("127.0.0.1", "0.0.0.0") else args.bind
    url = "http://%s:%d/" % (host, port)

    print()
    print("  SuperTuxKart is ready. Open this in your browser:")
    print()
    print("      %s" % url)
    print()
    print("  Serving: %s" % root)
    print("  %s" % describe_bundle(root))
    print()
    print("  Leave this window open while you play.")
    print("  Close it, or press Ctrl+C, to stop.")
    print()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - last resort for a double-click
        wait_for_exit("Unexpected error: %s" % exc, 1)
