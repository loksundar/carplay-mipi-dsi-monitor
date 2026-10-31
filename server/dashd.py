#!/usr/bin/env python3
"""Command server for the V831 screen (remote control without reflashing).

GET /cmd                        -> contents of cmd.sh (once; it is then renamed cmd.sh.sent)
POST /result                    -> device's output of that command, appended to results.log
POST /upload/NAME               -> saved as uploads/NAME (device screenshots etc.)
GET /files/NAME                 -> files/NAME, for pushing binaries to the device

The device polls /cmd every 3 s with httpc (see overlay/usr/bin/dash_start.sh).
"""
import datetime
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = pathlib.Path(__file__).resolve().parent


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        path = urlparse(self.path).path
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if path == "/result":
            with open(HERE / "results.log", "ab") as f:
                f.write(f"===== {datetime.datetime.now():%H:%M:%S}\n".encode() + data + b"\n")
        elif path.startswith("/upload/"):
            # raw files from the device, e.g. a /dev/fb0 screenshot
            (HERE / "uploads").mkdir(exist_ok=True)
            (HERE / "uploads" / pathlib.Path(path).name).write_bytes(data)
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, fmt, *args):
        if not self.path.startswith("/cmd"):  # the device polls /cmd every few seconds
            super().log_message(fmt, *args)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/cmd":
            cmd = HERE / "cmd.sh"
            try:
                body = cmd.read_bytes()
                cmd.replace(HERE / "cmd.sh.sent")
            except FileNotFoundError:
                body = b""
            ctype = "text/plain"
        elif url.path.startswith("/files/"):
            f = HERE / "files" / pathlib.Path(url.path).name
            if not f.is_file():
                self.send_error(404)
                return
            body, ctype = f.read_bytes(), "application/octet-stream"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
    print(f"command server on :{port}")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
