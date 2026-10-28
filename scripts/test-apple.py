#!/usr/bin/env python3
"""Exercise the shared iOS/macOS offline models with authenticated HTTP and real audio."""
import hashlib
import json
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from version import ROOT


def main():
    with tempfile.TemporaryDirectory(prefix="resona-apple-test-") as tmp:
        folder = Path(tmp)
        audio = folder / "song.mp3"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                        "-t", "12", "-c:a", "libmp3lame", str(audio)], check=True)
        data = audio.read_bytes()
        track_id = hashlib.sha256(data).hexdigest()
        track = dict(id=track_id, title="Offline Song", artist="Resona", album_artist="Resona", album="Offline",
                     year="2026", number=1, disc=1, duration=12, format="mp3", bitrate=128000,
                     sample_rate=44100, artwork=f"/api/v1/tracks/{track_id}/cover", favorite=False)
        cloud_id = hashlib.sha256(b"115:42:7").hexdigest()
        cloud_track = dict(track, id=cloud_id, title="Cloud Song", library="cloud",
                           hash_algorithm="sha1", content_hash=hashlib.sha1(data).hexdigest(),
                           artwork=f"/api/v1/tracks/{cloud_id}/cover")
        offline = False
        expired = False

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_PUT(self):
                if self.path.endswith('/favorite') and self.headers.get('Authorization') == 'Bearer test-session':
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    self.respond(dict(track, favorite=body['favorite']))
                else:
                    self.respond({}, status=401)

            def do_POST(self):
                nonlocal offline, expired
                if self.path == "/music/__offline":
                    offline = True
                    self.respond({})
                elif self.path == "/music/__expire":
                    expired = True
                    self.respond({})
                elif self.path == "/music/api/v1/auth/login":
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    expired = False
                    self.respond({"token": "test-session"} if body == {"username": "admin", "password": "test-password"} else {},
                                 status=200 if body.get("password") == "test-password" else 401)
                else:
                    self.respond({"error": "offline"}, status=503)

            def do_GET(self):
                if offline:
                    return self.respond({"error": "offline"}, status=503)
                path = self.path.split("?")[0]
                if path.endswith("/test-cloud-audio"):
                    return self.respond(data, "audio/mpeg")
                authenticated = (self.headers.get("Authorization") == "Bearer test-session"
                                 or "resona_session=test-session" in self.headers.get("Cookie", ""))
                if expired or not authenticated:
                    return self.respond({}, status=401)
                if path.endswith("/tracks"):
                    self.respond({"items": [cloud_track if "library=cloud" in self.path else track], "total": 1})
                elif path.endswith("/albums"):
                    self.respond({"items": []})
                elif path.endswith("/artists"):
                    self.respond({"items": [{"name": "Resona", "tracks": 1,
                                             "artwork": "/api/v1/artists/avatar?name=Resona"}]})
                elif path.endswith("/artists/avatar"):
                    self.respond((ROOT / "ios/Resona/Assets.xcassets/BrandIcon.imageset/BrandIcon.png").read_bytes(), "image/png")
                elif path.endswith("/stream"):
                    if cloud_id in path:
                        self.send_response(302)
                        self.send_header("Location", "/music/api/v1/test-cloud-audio")
                        self.end_headers()
                    else:
                        self.respond(data, "audio/mpeg")
                elif path.endswith("/cover"):
                    self.respond((ROOT / "ios/Resona/Assets.xcassets/BrandIcon.imageset/BrandIcon.png").read_bytes(), "image/png")
                elif path.endswith("/lyrics"):
                    self.respond(b"[00:00.00]Offline first line\n[00:02.00]Offline second line", "text/plain")
                else:
                    self.respond({}, status=404)

            def respond(self, value, content_type="application/json", status=200):
                payload = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            sources = [ROOT / "ios/Resona" / name for name in ("API.swift", "Lyrics.swift", "Offline.swift", "Player.swift")]
            executable = folder / "offline-tests"
            subprocess.run(["swiftc", "-swift-version", "5", *map(str, sources), str(ROOT / "ios/Tests/OfflineTests.swift"), "-o", str(executable)], check=True)
            subprocess.run([str(executable), str(audio), f"http://127.0.0.1:{server.server_port}/music"], check=True, timeout=60)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
