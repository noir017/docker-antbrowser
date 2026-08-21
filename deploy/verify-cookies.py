#!/usr/bin/env python3
"""Read cookies out of a live browser over CDP.

The point is not the count -- that we can get from the SQLite file. The point is
that the *browser* returns cookie values, which means it successfully decrypted
them with a key derived on this machine, in this container, under this core. That
is the thing that would silently break in a migration and the thing a file-level
check cannot prove.
"""
import json
import socket
import sys
import base64
import os
import struct


def ws_connect(host, port, path):
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection((host, port), timeout=15)
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("handshake closed early")
        buf += chunk
    if b"101" not in buf.split(b"\r\n")[0]:
        raise RuntimeError(f"handshake failed: {buf.split(chr(13).encode())[0]}")
    return sock


def ws_send(sock, payload):
    data = payload.encode()
    header = bytearray([0x81])
    mask = os.urandom(4)
    n = len(data)
    if n < 126:
        header.append(0x80 | n)
    elif n < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", n)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", n)
    header += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    sock.sendall(bytes(header) + masked)


def ws_recv(sock):
    def read(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("connection closed")
            buf += chunk
        return buf

    while True:
        h = read(2)
        opcode = h[0] & 0x0F
        length = h[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", read(8))[0]
        payload = read(length)
        if opcode == 1:
            return payload.decode()
        if opcode == 8:
            raise RuntimeError("server closed")


def call(sock, mid, method, params=None):
    ws_send(sock, json.dumps({"id": mid, "method": method, "params": params or {}}))
    while True:
        msg = json.loads(ws_recv(sock))
        if msg.get("id") == mid:
            return msg


def main():
    port = int(sys.argv[1])
    path = sys.argv[2]
    sock = ws_connect("127.0.0.1", port, path)

    res = call(sock, 1, "Storage.getCookies")
    cookies = res.get("result", {}).get("cookies", [])

    decrypted = [c for c in cookies if c.get("value")]
    print(f"cookies_total={len(cookies)}")
    print(f"cookies_with_readable_value={len(decrypted)}")

    domains = sorted({c["domain"].lstrip(".") for c in cookies})
    print(f"distinct_domains={len(domains)}")
    for d in domains[:12]:
        print(f"  {d}")

    # Show that values are real content, not empty strings from a failed decrypt.
    print("samples:")
    for c in decrypted[:5]:
        val = c["value"]
        shown = val[:14] + ("..." if len(val) > 14 else "")
        print(f"  {c['domain'].lstrip('.')}/{c['name']} = {shown}")

    if cookies and not decrypted:
        print("VERDICT=DECRYPT_FAILED")
        return 1
    if not cookies:
        print("VERDICT=NO_COOKIES")
        return 1
    print("VERDICT=DECRYPT_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
