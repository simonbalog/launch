#!/usr/bin/env python3
"""Small, loopback-only static server for live HLS segments."""

import argparse
import http.server
import json
import os
import re
import socket
import sys
import threading
from functools import partial
from pathlib import Path
from urllib.parse import urlsplit

SEGMENT_RE = re.compile(r"seg_\d{5}\.ts\Z")
PLAYLIST_NAME = "index.m3u8"


class HLSHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LaunchHLS/1.0"
    sys_version = ""

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".ts": "video/mp2t",
        ".m4s": "video/iso.segment",
        ".mp4": "video/mp4",
    }

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def _name(self):
        # Reject encoded separators and nested paths; only known HLS filenames
        # should ever be exposed through the public tunnel.
        parsed = urlsplit(self.path)
        if parsed.path.count("/") != 1 or "%2f" in parsed.path.lower() or "%5c" in parsed.path.lower():
            return None
        name = parsed.path[1:]
        if name == PLAYLIST_NAME or SEGMENT_RE.fullmatch(name):
            return name
        return None

    def _health(self):
        root = Path(self.directory)
        playlist = root / PLAYLIST_NAME
        try:
            text = playlist.read_text(encoding="utf-8")
            ready = any(
                line.startswith("seg_") and SEGMENT_RE.fullmatch(line)
                and (root / line).is_file() and not (root / line).is_symlink()
                for line in text.splitlines()
            )
        except (OSError, UnicodeError):
            ready = False
        body = json.dumps({"ok": ready}, separators=(",", ":")).encode("utf-8")
        self.send_response(200 if ready else 503)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        if self._name() is None and urlsplit(self.path).path != "/health":
            self.send_error(404)
            return
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if urlsplit(self.path).path == "/health":
            self._health()
            return
        name = self._name()
        if name is None:
            self.send_error(404)
            return
        target = Path(self.directory) / name
        if target.is_symlink() or not target.is_file():
            self.send_error(404)
            return
        super().do_GET()

    def do_HEAD(self):
        if urlsplit(self.path).path == "/health":
            self._health()
            return
        name = self._name()
        if name is None:
            self.send_error(404)
            return
        target = Path(self.directory) / name
        if target.is_symlink() or not target.is_file():
            self.send_error(404)
            return
        super().do_HEAD()

    def log_message(self, fmt, *args):
        # Keep request logs useful while not writing publicly requested URLs
        # (which may contain sensitive query strings) to disk.
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", default="stream/hls")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    try:
        address = socket.getaddrinfo(args.host, args.port, type=socket.SOCK_STREAM)[0][4][0]
        if not ipaddress_is_loopback(address):
            parser.error("server may only bind to a loopback address; expose it through the tunnel")
        if not 1 <= args.port <= 65535:
            parser.error("port must be between 1 and 65535")
        directory = os.path.realpath(args.dir)
        if not os.path.isdir(directory):
            parser.error(f"HLS directory does not exist: {directory}")
        handler = partial(HLSHandler, directory=directory)
        server = http.server.ThreadingHTTPServer((args.host, args.port), handler)
        server.daemon_threads = True
        server.timeout = 1
        print(f"serving HLS from {directory} on http://{args.host}:{args.port}", flush=True)
        try:
            server.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            server.shutdown()
            server.server_close()
    except OSError as exc:
        parser.error(str(exc))


def ipaddress_is_loopback(address):
    import ipaddress
    try:
        return ipaddress.ip_address(address).is_loopback
    except ValueError:
        return False


if __name__ == "__main__":
    main()
