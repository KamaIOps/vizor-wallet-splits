#!/usr/bin/env python3
"""A TCP relay in front of lightwalletd that can hold back a transaction.

    lwd-hold-proxy.py <listen-port> <upstream-port> <mode-file>

Every connection is relayed byte for byte to 127.0.0.1:<upstream-port>. While
<mode-file> reads `hold`, a client chunk of HOLD_BYTES or more is not
forwarded and its connection is left open with nothing answered: that is a
SendTransaction carrying a raw transaction, since every other request a wallet
makes is a few hundred bytes. The wallet has built and stored the transaction
by then and is waiting on the broadcast, which never reaches the node. The
proxy prints `HELD <n> bytes` once per held chunk.

While <mode-file> reads `drop`, such a chunk is not forwarded either, and its
connection is closed at once, so the broadcast fails and the wallet reconnects
for everything else. Every rebroadcast of a stored transaction is refused this
way until it expires. The proxy prints `DROPPED <n> bytes` once per chunk.

Any other content of <mode-file>, or no file, relays everything.
"""

import os
import socket
import sys
import threading

HOLD_BYTES = 1000


def mode(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def pipe(src, dst, mode_file, upstream):
    held = False
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if held:
                continue
            if upstream and len(data) >= HOLD_BYTES:
                current = mode(mode_file)
                if current == "hold":
                    held = True
                    print(f"HELD {len(data)} bytes", flush=True)
                    continue
                if current == "drop":
                    print(f"DROPPED {len(data)} bytes", flush=True)
                    break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        if not held:
            for s in (src, dst):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass


def serve(client, upstream_port, mode_file):
    try:
        server = socket.create_connection(("127.0.0.1", upstream_port))
    except OSError:
        client.close()
        return
    threading.Thread(target=pipe, args=(client, server, mode_file, True), daemon=True).start()
    threading.Thread(target=pipe, args=(server, client, mode_file, False), daemon=True).start()


def main():
    listen_port, upstream_port, mode_file = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", listen_port))
    listener.listen(64)
    print(f"relaying {listen_port} -> {upstream_port}", flush=True)
    while True:
        client, _ = listener.accept()
        serve(client, upstream_port, mode_file)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        os._exit(0)
