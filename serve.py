#!/usr/bin/env python3
"""Static server for the SuperTuxKart WebAssembly launcher.

The engine is compiled with -pthread, so it needs SharedArrayBuffer, which
browsers only hand out to cross-origin isolated pages. That means these two
headers are mandatory:

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp

Python's plain `http.server` does not send them, so opening the page through it
gives a runtime that never starts. This server adds them, serves the right MIME
type for .wasm, and handles requests on threads so the game's worker threads can
fetch in parallel with the main thread.

Usage:
    python3 serve.py [port] [--dir DIRECTORY]
"""

import argparse
import functools
import os
import socket
import sys
from http import server


class Handler(server.SimpleHTTPRequestHandler):
    extensions_map = {
        **server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".json": "application/json",
        ".data": "application/octet-stream",
        ".manifest": "text/plain",
    }

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        # The bundle parts are content-addressed by the build, but the launcher
        # and config change often enough that caching them is a nuisance.
        if self.path.endswith((".html", ".json")) or self.path in ("/", ""):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        if os.environ.get("STK_QUIET"):
            return
        super().log_message(fmt, *args)


class Server(server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port", nargs="?", type=int, default=8000)
    parser.add_argument("--dir", default=os.path.dirname(os.path.abspath(__file__)),
                        help="directory to serve (defaults to this file's folder)")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="address to bind (use 0.0.0.0 to allow other machines)")
    args = parser.parse_args()

    root = os.path.abspath(args.dir)
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    if not os.path.isdir(os.path.join(root, "game")):
        print("note: no 'game/' directory here, so the launcher will report the",
              "build as missing. See README.md for how to produce it.\n", file=sys.stderr)

    handler = functools.partial(Handler, directory=root)
    try:
        httpd = Server((args.bind, args.port), handler)
    except OSError as exc:
        sys.exit(f"could not bind {args.bind}:{args.port} ({exc})")

    host = args.bind if args.bind != "0.0.0.0" else socket.gethostname()
    print(f"serving {root}")
    print(f"open http://{host}:{args.port}/  (cross-origin isolation enabled)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
