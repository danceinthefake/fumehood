#!/usr/bin/env python3
"""Proves fumehood's ssh_tunnel identity on a real GCP VM (DESIGN.md §6.2).

Run on the VM (no fumehood needed, only Python 3):

    python3 ssh-tunnel-identity-check.py          # listens on 127.0.0.1:4000

Then, from two laptops logged in to gcloud as two different people:

    gcloud compute ssh VM --tunnel-through-iap -- -N -L 4000:localhost:4000
    curl http://localhost:4000/

Each curl must print that person's OS Login username. The server log shows
peer, uid and user for every connection. Same lookup as Fumehood.Identity:
the uid owning the client end of the connection in /proc/net/tcp{,6}.
"""
import http.server
import pwd
import socket
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 4000


def parse(addr):
    ip_hex, port_hex = addr.split(":")
    raw = bytes.fromhex(ip_hex)
    words = struct.unpack("<" + "I" * (len(raw) // 4), raw)
    packed = b"".join(struct.pack(">I", w) for w in words)
    if len(packed) == 16 and packed[:12] == b"\0" * 10 + b"\xff\xff":
        packed = packed[12:]  # IPv4-mapped IPv6
    family = socket.AF_INET if len(packed) == 4 else socket.AF_INET6
    return socket.inet_ntop(family, packed), int(port_hex, 16)


def owner(peer, local):
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        with open(path) as f:
            next(f)
            for line in f:
                cols = line.split()
                if parse(cols[1]) == peer and parse(cols[2]) == local:
                    return int(cols[7])
    return None


def normalize(addr):
    host, port = addr[0], addr[1]
    if host.startswith("::ffff:"):
        host = host[7:]
    return host, port


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        peer = normalize(self.client_address)
        local = normalize(self.request.getsockname())
        uid = owner(peer, local)
        user = pwd.getpwuid(uid).pw_name if uid is not None else None
        print(f"peer={peer} uid={uid} user={user}", flush=True)
        body = (user or "UNKNOWN (would be 401)").encode() + b"\n"
        self.send_response(200 if user else 401)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


print(f"listening on 127.0.0.1:{PORT}", flush=True)
http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
