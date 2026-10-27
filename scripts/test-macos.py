#!/usr/bin/env python3
"""Exercise native macOS lyrics and menu bar playback without the user's library."""
import argparse
import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from version import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", action="store_true")
    args = parser.parse_args()
    build = ROOT / ".build/macos-tests"
    build.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                    "-t", "12", "-c:a", "libmp3lame", str(build / "song.mp3")], check=True)
    sources = [ROOT / "ios/Resona" / name for name in ("API.swift", "Player.swift", "Lyrics.swift", "Offline.swift")]
    sources += sorted(path for path in (ROOT / "macos/Resona").glob("*.swift") if path.name != "ResonaApp.swift")
    executable = build / "desktop-tests"
    subprocess.run(["swiftc", "-swift-version", "5", *map(str, sources), str(ROOT / "macos/Tests/DesktopTests.swift"),
                    "-o", str(executable)], check=True)
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            track = json.loads((build / "track.json").read_text())
            authorized = self.headers.get("Authorization") == "Bearer test-session"
            prefix = f"/api/v1/tracks/{track['id']}/"
            if authorized and self.path == prefix + "stream":
                data = (build / "song.mp3").read_bytes()
            elif authorized and self.path == prefix + "lyrics":
                data = b'[00:00]Downloaded lyric'
            else:
                self.send_error(401 if not authorized else 404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_PUT(self):
            track = json.loads((build / "track.json").read_text())
            authorized = self.headers.get("Authorization") == "Bearer test-session"
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            valid = self.path == f"/api/v1/tracks/{track['id']}/favorite" and type(payload.get("favorite")) is bool
            if authorized and valid:
                track["favorite"] = payload["favorite"]
            data = json.dumps(track if authorized and valid else {"error": "unauthorized"}).encode()
            self.send_response(200 if authorized and valid else 401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(executable), str(build), f"http://127.0.0.1:{server.server_port}",
                        *(["--capture"] if args.capture else [])], check=True, timeout=60)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
