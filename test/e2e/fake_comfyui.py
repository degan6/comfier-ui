"""A fake ComfyUI for script/agent_e2e: accepts prompts and "runs" them, producing a real PNG.

POST /_e2e/execute_seconds {"seconds": N} changes how long each prompt takes.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import struct
import sys
import zlib

from aiohttp import web

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "comfyui", "comfier_agent", "tests"))

from fake_comfy import FakeComfy  # noqa: E402


def png(width: int = 8, height: int = 8) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\x00" + b"\xd0\x60\x30" * width for _ in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


class RunningComfy(FakeComfy):
    def __init__(self, execute_seconds: float):
        super().__init__()
        self.execute_seconds = execute_seconds
        self.object_info_data = {
            "LoadImage": {"input": {"required": {"image": [["example.png"]]}}},
            "SaveImage": {"input": {"required": {"images": ["IMAGE"]}}},
        }
        self.models_data = {"checkpoints": []}
        self.app.router.add_post("/_e2e/execute_seconds", self.set_execute_seconds)

    async def prompt(self, request):
        response = await super().prompt(request)
        if response.status == 200:
            asyncio.create_task(self._execute(f"p_{self.prompt_counter}"))
        return response

    async def _execute(self, prompt_id: str) -> None:
        await self.push_ws({"type": "execution_start", "prompt_id": prompt_id})
        await self.push_ws({"type": "executing", "prompt_id": prompt_id, "node": "2"})
        steps = 5
        for step in range(steps):
            await asyncio.sleep(self.execute_seconds / steps)
            await self.push_ws({"type": "progress", "prompt_id": prompt_id, "value": step + 1, "max": steps})
        filename = f"e2e_{prompt_id}.png"
        self.output_files[filename] = png()
        self.history[prompt_id] = {
            "outputs": {"2": {"images": [{"filename": filename, "subfolder": "", "type": "output"}]}},
        }
        await self.push_ws({"type": "executing", "prompt_id": prompt_id, "node": None})
        await self.push_ws({"type": "execution_success", "prompt_id": prompt_id})

    async def set_execute_seconds(self, request):
        self.execute_seconds = float((await request.json())["seconds"])
        return web.json_response({"execute_seconds": self.execute_seconds})


async def main(port: int, execute_seconds: float) -> None:
    comfy = RunningComfy(execute_seconds)
    runner = web.AppRunner(comfy.app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()
    print(f"fake ComfyUI on http://127.0.0.1:{port}", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8199)
    parser.add_argument("--execute-seconds", type=float, default=1.0)
    args = parser.parse_args()
    asyncio.run(main(args.port, args.execute_seconds))
