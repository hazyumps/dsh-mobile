#!/usr/bin/env python3
"""Measure mux frame sizes over a raw WebSocket, to find what the phone cannot receive.

URLSessionWebSocketTask fails a large inbound frame with EMSGSIZE ("Message too
long"). This reads the same stream with no such limit and prints each frame's byte
size, so the fix can be aimed at the right cause. Read-only: it opens streams and
sends nothing else.

Usage: mux-sizes.py <sessionId>
"""
import base64
import json
import os
import socket
import ssl
import struct
import sys

HOST, PORT = "127.0.0.1", 3443
session_id = sys.argv[1] if len(sys.argv) > 1 else "session-example"


def connect():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((HOST, PORT), timeout=20)
    tls = ctx.wrap_socket(raw, server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    tls.sendall(
        (
            f"GET /api/remote.mux HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    header = b""
    while b"\r\n\r\n" not in header:
        header += tls.recv(1)
    print("handshake:", header.split(b"\r\n")[0].decode())
    return tls


def send_text(sock, text):
    payload = text.encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    header = bytearray([0x81])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header += struct.pack("!H", length)
    else:
        header.append(0x80 | 127)
        header += struct.pack("!Q", length)
    sock.sendall(bytes(header) + mask + masked)


def read_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError("socket closed")
        data += chunk
    return data


def read_frame(sock):
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    payload = read_exact(sock, length)
    return opcode, payload


def main():
    sock = connect()
    send_text(sock, json.dumps({"type": "open", "streamId": "events-1", "endpoint": "$events",
                                "payload": {"args": {}}}))
    opcode, payload = read_frame(sock)
    print(f"events frame: opcode={opcode} bytes={len(payload)} {payload[:120]!r}")

    follow = json.dumps({"type": "open", "streamId": "follow-1", "endpoint": "session/follow",
                         "payload": {"args": {"request": {
                             "address": {"kind": "session", "sessionId": session_id},
                             "assistantStream": True, "maxMessages": int(sys.argv[2]) if len(sys.argv) > 2 else 60}}}})
    print("follow request bytes:", len(follow))
    send_text(sock, follow)

    for _ in range(6):
        try:
            opcode, payload = read_frame(sock)
        except (EOFError, socket.timeout) as error:
            print("stream ended:", error)
            break
        head = payload[:160].decode("utf-8", "replace")
        print(f"frame: opcode={opcode} bytes={len(payload)} head={head}")


main()
