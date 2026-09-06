#!/usr/bin/env python3
"""Minimal TLS WebSocket fixture for the Hermes Desktop mobile CI contract."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
import ssl
import struct
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
AVATAR_DATA_URL = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def websocket_accept(key: str) -> str:
    digest = hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def read_exact(connection: ssl.SSLSocket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(connection: ssl.SSLSocket) -> tuple[int, bytes]:
    first, second = read_exact(connection, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(connection, 8))[0]
    mask = read_exact(connection, 4) if masked else b""
    payload = read_exact(connection, length)
    if masked:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload


def send_frame(connection: ssl.SSLSocket, opcode: int, payload: bytes) -> None:
    length = len(payload)
    header = bytearray([0x80 | opcode])
    if length < 126:
        header.append(length)
    elif length <= 0xFFFF:
        header.append(126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", length))
    connection.sendall(bytes(header) + payload)


def send_json(connection: ssl.SSLSocket, value: object) -> None:
    send_frame(connection, 0x1, json.dumps(value, separators=(",", ":")).encode("utf-8"))


class Receipt:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.Lock()
        self.tcp_connections = 0
        self.tls_connections = 0
        self.http_paths: list[str] = []
        self.websocket_connections = 0
        self.connection_errors: list[str] = []
        self.methods: list[str] = []
        self.profiles_requested = False
        self.avatar_requests = 0
        self.created_profile: str | None = None
        self.prompt_text: str | None = None

    def tcp_connected(self) -> None:
        with self.lock:
            self.tcp_connections += 1
            self._write()

    def tls_connected(self) -> None:
        with self.lock:
            self.tls_connections += 1
            self._write()

    def http_requested(self, path: str) -> None:
        with self.lock:
            self.http_paths.append(path)
            self._write()

    def websocket_connected(self) -> None:
        with self.lock:
            self.websocket_connections += 1
            self._write()

    def connection_failed(self, error: BaseException) -> None:
        error_name = type(error).__name__
        with self.lock:
            self.connection_errors.append(error_name)
            self._write()

    def record(self, method: str, params: dict[str, object]) -> None:
        with self.lock:
            self.methods.append(method)
            if method == "profiles.list":
                self.profiles_requested = params.get("include_sessions") is True
            elif method == "profiles.get_asset" and params.get("asset") == "avatar":
                self.avatar_requests += 1
            elif method == "session.create":
                profile = params.get("profile")
                self.created_profile = profile if isinstance(profile, str) else None
            elif method == "prompt.submit":
                text = params.get("text")
                self.prompt_text = text if isinstance(text, str) else None
            self._write()

    def _write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "tcp_connections": self.tcp_connections,
            "tls_connections": self.tls_connections,
            "http_paths": self.http_paths,
            "websocket_connections": self.websocket_connections,
            "connection_errors": self.connection_errors,
            "methods": self.methods,
            "profiles_requested_with_sessions": self.profiles_requested,
            "avatar_requests": self.avatar_requests,
            "created_profile": self.created_profile,
            "prompt_text": self.prompt_text,
        }
        self.path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


class HermesGatewayFixture:
    def __init__(self, host: str, port: int, token: str, certificate: Path, key: Path, receipt: Receipt) -> None:
        self.host = host
        self.port = port
        self.token = token
        self.receipt = receipt
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(certificate, key)

    def serve_forever(self) -> None:
        with socket.create_server((self.host, self.port), reuse_port=False) as listener:
            while True:
                raw_connection, _ = listener.accept()
                self.receipt.tcp_connected()
                thread = threading.Thread(target=self._handle_safely, args=(raw_connection,), daemon=True)
                thread.start()

    def _handle_safely(self, raw_connection: socket.socket) -> None:
        try:
            with self.context.wrap_socket(raw_connection, server_side=True) as connection:
                self.receipt.tls_connected()
                self._handle(connection)
        except (ConnectionError, OSError, ssl.SSLError, ValueError, json.JSONDecodeError) as error:
            self.receipt.connection_failed(error)
            print(f"Hermes gateway fixture connection failed: {type(error).__name__}", file=sys.stderr, flush=True)
            raw_connection.close()

    def _handle(self, connection: ssl.SSLSocket) -> None:
        request = bytearray()
        while b"\r\n\r\n" not in request:
            request.extend(connection.recv(4096))
            if len(request) > 65_536:
                raise ValueError("request headers too large")

        header_text = bytes(request).split(b"\r\n\r\n", 1)[0].decode("iso-8859-1")
        lines = header_text.split("\r\n")
        method, target, _ = lines[0].split(" ", 2)
        headers = {
            name.strip().lower(): value.strip()
            for line in lines[1:]
            if ":" in line
            for name, value in [line.split(":", 1)]
        }
        query = parse_qs(urlsplit(target).query)
        path = urlsplit(target).path
        self.receipt.http_requested(path)
        if method != "GET" or path != "/api/ws" or query.get("token") != [self.token]:
            connection.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
            return

        key = headers.get("sec-websocket-key")
        if not key:
            raise ValueError("missing Sec-WebSocket-Key")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {websocket_accept(key)}\r\n\r\n"
        )
        connection.sendall(response.encode("ascii"))
        self.receipt.websocket_connected()
        send_json(
            connection,
            {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
        )

        while True:
            opcode, payload = read_frame(connection)
            if opcode == 0x8:
                send_frame(connection, 0x8, b"")
                return
            if opcode == 0x9:
                send_frame(connection, 0xA, payload)
                continue
            if opcode != 0x1:
                continue

            request_value = json.loads(payload.decode("utf-8"))
            request_id = request_value.get("id")
            method_name = request_value.get("method")
            params = request_value.get("params")
            if not isinstance(request_id, int) or not isinstance(method_name, str) or not isinstance(params, dict):
                continue
            self.receipt.record(method_name, params)
            self._respond(connection, request_id, method_name, params)

    def _respond(self, connection: ssl.SSLSocket, request_id: int, method: str, params: dict[str, object]) -> None:
        if method == "profiles.list":
            result = {
                "profiles": [
                    {
                        "name": "default",
                        "display_name": "Hermes",
                        "description": "Primary Hermes agent",
                        "model": "gpt-5.6-sol",
                        "provider": "openai",
                        "skill_count": 41,
                        "is_default": True,
                        "has_avatar": True,
                        "last_session": {
                            "id": "release-session",
                            "resolved_id": "release-session-tip",
                            "title": "Hermes mobile release",
                            "preview": "Checking the secure gateway",
                            "message_count": 8,
                        },
                    },
                    {
                        "name": "research",
                        "display_name": "Research",
                        "description": "Evidence and source review",
                        "model": "gpt-5.6-terra",
                        "provider": "openai",
                        "skill_count": 19,
                        "is_default": False,
                        "has_avatar": True,
                    },
                    {
                        "name": "qa",
                        "display_name": "QA",
                        "description": "Independent verification",
                        "model": "gpt-5.6-terra",
                        "provider": "openai",
                        "skill_count": 12,
                        "is_default": False,
                        "has_avatar": True,
                    },
                ]
            }
            send_json(connection, {"jsonrpc": "2.0", "id": request_id, "result": result})
            return

        if method == "profiles.get_asset":
            found = params.get("name") in {"default", "research", "qa"} and params.get("asset") == "avatar"
            result = {"found": found, "data": AVATAR_DATA_URL if found else None}
            send_json(connection, {"jsonrpc": "2.0", "id": request_id, "result": result})
            return

        if method == "session.create":
            profile = params.get("profile")
            result = {
                "session_id": "runtime-mobile-ci",
                "stored_session_id": "stored-mobile-ci",
                "title": "Mobile gateway proof",
                "messages": [],
                "info": {"model": "gpt-5.6-terra", "provider": "openai", "profile": profile},
            }
            send_json(connection, {"jsonrpc": "2.0", "id": request_id, "result": result})
            return

        if method == "prompt.submit":
            text = params.get("text")
            send_json(connection, {"jsonrpc": "2.0", "id": request_id, "result": {"accepted": True}})
            send_json(
                connection,
                {
                    "jsonrpc": "2.0",
                    "method": "event",
                    "params": {
                        "type": "message.delta",
                        "session_id": "runtime-mobile-ci",
                        "profile": "research",
                        "payload": {"delta": "Hermes mobile gateway "},
                    },
                },
            )
            send_json(
                connection,
                {
                    "jsonrpc": "2.0",
                    "method": "event",
                    "params": {
                        "type": "message.complete",
                        "session_id": "runtime-mobile-ci",
                        "profile": "research",
                        "payload": {
                            "message_id": "assistant-mobile-ci",
                            "role": "assistant",
                            "content": "Hermes mobile gateway verified.",
                            "echo": text,
                        },
                    },
                },
            )
            return

        send_json(
            connection,
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"unsupported fixture method: {method}"},
            },
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    fixture = HermesGatewayFixture(
        host=args.host,
        port=args.port,
        token=args.token,
        certificate=args.certificate,
        key=args.key,
        receipt=Receipt(args.receipt),
    )
    fixture.serve_forever()


if __name__ == "__main__":
    main()
