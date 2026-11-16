#!/usr/bin/env python3
"""Basic regression tests for the loopback HLS HTTP server."""

import http.server
import tempfile
import threading
import unittest
from functools import partial
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from hls_server import HLSHandler


class HLSHandlerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "index.m3u8").write_text("#EXTM3U\n#EXTINF:1,\nseg_00001.ts\n", encoding="utf-8")
        (self.root / "seg_00001.ts").write_bytes(b"video")
        handler = partial(HLSHandler, directory=str(self.root))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2)
        self.tmp.cleanup()

    def test_health_is_ready_only_with_a_segment(self):
        with urlopen(self.base + "/health") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Content-Type"].split(";")[0], "application/json")
        (self.root / "seg_00001.ts").unlink()
        with self.assertRaises(HTTPError) as error:
            urlopen(self.base + "/health")
        self.assertEqual(error.exception.code, 503)

    def test_serves_playlist_with_no_cache_and_cors(self):
        with urlopen(self.base + "/index.m3u8") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")
            self.assertIn("no-store", response.headers["Cache-Control"])
            self.assertIn("#EXTM3U", response.read().decode())

    def test_rejects_unlisted_paths_and_nested_paths(self):
        for path in ("/", "/secret.txt", "/../README.md", "/seg_00001.ts/extra"):
            with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                urlopen(self.base + path)
            self.assertEqual(error.exception.code, 404)

    def test_options_is_restricted(self):
        request = Request(self.base + "/index.m3u8", method="OPTIONS")
        with urlopen(request) as response:
            self.assertEqual(response.status, 204)
        request = Request(self.base + "/secret.txt", method="OPTIONS")
        with self.assertRaises(HTTPError) as error:
            urlopen(request)
        self.assertEqual(error.exception.code, 404)

    def test_symlink_segments_are_not_served(self):
        outside = self.root.parent / (self.root.name + "-secret")
        outside.write_text("secret", encoding="utf-8")
        try:
            (self.root / "seg_00002.ts").symlink_to(outside)
            with self.assertRaises(HTTPError) as error:
                urlopen(self.base + "/seg_00002.ts")
            self.assertEqual(error.exception.code, 404)
        finally:
            outside.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
