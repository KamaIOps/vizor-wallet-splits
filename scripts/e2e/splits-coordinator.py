#!/usr/bin/env python3
"""Hands out roles and passes values between devices in a multi-device lane.

`--dart-define` is compile-time, so a lane that gives each device a different
one needs a different binary per device — and concurrent builds in this
project's single `build/` directory clobber each other, leaving every device
running whichever finished last. Serialising the builds works and costs four
minutes of wall clock before the flow can start.

This removes the reason for it. Every device is launched with the SAME defines
and asks, at runtime, which one it is. One binary, built once, and the devices
start together.

It also carries the values a lane used to scrape out of stdout — the bill code,
an address — so the sequencer no longer greps a log to decide what to do next.

    POST /claim            -> {"role": "payer"}    in arrival order
    PUT  /kv/<key>  <body> -> 204, or 411 without a content-length
    GET  /kv/<key>         -> the body, or 404 until it is there

Loopback only: the simulators reach the host on 127.0.0.1, which is how they
already reach the relay.

    python3 splits-coordinator.py --port 39400 --roles payer,zec,usdc,cash
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
ROLES: list[str] = []
CLAIMED: list[str] = []
STORE: dict[str, bytes] = {}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes = b"", kind: str = "text/plain"):
        self.send_response(code)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        if self.path != "/claim":
            return self._send(404)
        with LOCK:
            if not ROLES:
                # Every role taken. Said plainly: a fifth device in a
                # four-device lane is a mistake in the sequencer, not a queue.
                return self._send(409, b"no roles left")
            role = ROLES.pop(0)
            CLAIMED.append(role)
        self._send(200, json.dumps({"role": role}).encode(), "application/json")

    def do_PUT(self):
        if not self.path.startswith("/kv/"):
            return self._send(404)
        raw = self.headers.get("content-length")
        if raw is None:
            # This reader takes exactly the number of bytes the header names,
            # so a chunked body would be stored as nothing at all — and a key
            # holding an empty value answers 200 to every device waiting on
            # it, which reads as a value that arrived.
            return self._send(411, b"send a content-length")
        length = int(raw)
        with LOCK:
            STORE[self.path[4:]] = self.rfile.read(length)
        self._send(204)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, b"ok")
        if not self.path.startswith("/kv/"):
            return self._send(404)
        with LOCK:
            value = STORE.get(self.path[4:])
        # 404 is "not yet", and a caller polls. An empty 200 would read as a
        # value that happens to be empty.
        self._send(404) if value is None else self._send(200, value)

    def log_message(self, fmt, *args):
        print(f"coordinator: {fmt % args}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=39400)
    parser.add_argument("--roles", default="payer,zec,usdc,cash")
    args = parser.parse_args()
    ROLES.extend(r for r in args.roles.split(",") if r)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"coordinator on http://127.0.0.1:{args.port} "
          f"(loopback only) roles={','.join(ROLES)}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
