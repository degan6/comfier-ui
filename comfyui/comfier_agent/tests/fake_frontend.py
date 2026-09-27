"""Fake Comfier frontend WebSocket server. Every message the agent sends is checked against the schema."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any, Awaitable, Callable

from aiohttp import WSMsgType, web
from jsonschema import Draft202012Validator

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "protocol" / "agent-v1.schema.json"
VALIDATOR = Draft202012Validator(json.loads(SCHEMA_PATH.read_text(encoding="utf-8")))


def schema_errors(msg: dict) -> list[str]:
    return [f"{msg.get('type')}: {e.message}" for e in VALIDATOR.iter_errors(msg)]


class FakeFrontend:
    def __init__(self, *, auth_key: str = "test-key"):
        self.auth_key = auth_key
        self.app = web.Application()
        self.app.router.add_get("/api/agent/ws", self.ws_handler)
        self.app.router.add_get("/api/agent/jobs/{job_id}/inputs/{input_id}", self.input_file)
        self.app.router.add_post("/api/agent/jobs/{job_id}/outputs", self.output_upload)
        self.runner: web.AppRunner | None = None
        self.base_url = ""
        self.messages: list[dict] = []
        self.invalid: list[str] = []
        self.ws: web.WebSocketResponse | None = None
        self.connections = 0
        self.on_message: Callable[[dict], Awaitable[None]] | None = None
        self.input_payload = b"input-image-bytes"
        self.uploads: list[dict] = []
        # Scripted upload replies, used in order: (status, json body). Then {"upload_id": "u_test"}.
        self.upload_replies: list[tuple[int, Any]] = []
        self.upload_attempts = 0
        self._send_assign: dict | None = None
        self.auth_header_seen: str | None = None

    async def start(self) -> str:
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]  # noqa: SLF001
        self.base_url = f"http://127.0.0.1:{port}"
        return self.base_url

    async def stop(self) -> None:
        if self.ws:
            await self.ws.close()
        if self.runner:
            await self.runner.cleanup()
        assert not self.invalid, f"agent sent messages that break the schema: {self.invalid}"

    async def ws_handler(self, request):
        auth = request.headers.get("Authorization")
        self.auth_header_seen = auth
        if auth != f"Bearer {self.auth_key}":
            return web.Response(status=401)
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.ws = ws
        self.connections += 1
        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    self.invalid.extend(schema_errors(data))
                    self.messages.append(data)
                    if self.on_message:
                        await self.on_message(data)
                    if data.get("type") == "job.request" and self._send_assign:
                        await ws.send_str(json.dumps(self._send_assign))
        finally:
            if self.ws is ws:
                self.ws = None
        return ws

    async def close_agent(self, code: int = 1000, message: bytes = b"") -> None:
        if self.ws:
            await self.ws.close(code=code, message=message)

    async def send(self, msg: dict) -> None:
        await self.ws.send_str(json.dumps(msg))

    async def input_file(self, request):
        if request.headers.get("Authorization") != f"Bearer {self.auth_key}":
            return web.Response(status=403)
        return web.Response(body=self.input_payload)

    async def output_upload(self, request):
        if request.headers.get("Authorization") != f"Bearer {self.auth_key}":
            return web.Response(status=403)
        self.upload_attempts += 1
        reader = await request.multipart()
        meta = {}
        while part := await reader.next():
            if part.name == "file":
                meta["bytes"] = await part.read()
            else:
                meta[part.name] = await part.text()
        if self.upload_replies:
            status, body = self.upload_replies.pop(0)
            return web.json_response(body, status=status)
        self.uploads.append(meta)
        return web.json_response({"upload_id": f"u_test_{len(self.uploads)}"})

    def of_type(self, typ: str) -> list[dict]:
        return [m for m in self.messages if m.get("type") == typ]

    async def wait_for_types(self, *types: str, timeout: float = 5.0, after: int = 0) -> list[dict]:
        deadline = asyncio.get_event_loop().time() + timeout
        wanted = set(types)
        while asyncio.get_event_loop().time() < deadline:
            found = {}
            for msg in self.messages[after:]:
                if msg.get("type") in wanted and msg.get("type") not in found:
                    found[msg["type"]] = msg
            if len(found) >= len(wanted):
                return list(found.values())
            await asyncio.sleep(0.05)
        raise TimeoutError(f"wanted {types}, got {[m.get('type') for m in self.messages[after:]]}")

    async def wait_for(self, predicate: Callable[[], bool], timeout: float = 5.0) -> None:
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            if predicate():
                return
            await asyncio.sleep(0.05)
        raise TimeoutError("condition not met")

    def queue_assign(self, assign: dict[str, Any]) -> None:
        self._send_assign = assign
