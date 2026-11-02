"""Native YuE2 and MiniMax music generation, with one cancellable worker per job."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import sys
import time
from typing import Any

from comfier_agent.engines.base import JobCancelled, JobContext, JobError, ProgressFn
from comfier_agent.engines.mlx import ChildProcess, MlxEngine
from comfier_agent.music_models import MODELS, validate_recipe

LOG = logging.getLogger("comfier_agent")


def default_worker_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.music_worker"]


class MlxMusicEngine(MlxEngine):
    name = "mlx_music"
    command = re.compile(r"^mlx_music\.generate$")

    def __init__(self, config, worker_argv: list[str] | None = None):
        super().__init__(config)
        self.worker_argv = worker_argv or default_worker_argv()
        self.process: ChildProcess | None = None

    def validate(self, workflow: Any) -> None:
        super().validate(workflow)
        try:
            validate_recipe(workflow)
        except ValueError as exc:
            raise JobError("validate", str(exc)) from exc

    async def refresh(self) -> None:
        if self._refreshed_at and time.monotonic() - self._refreshed_at < 600:
            return
        probe = ChildProcess("music inventory")
        try:
            await probe.start([*self.worker_argv, "--inventory"], stdout=True)
            out = await asyncio.wait_for(probe.proc.stdout.read(), 120)
            code = await probe.wait()
            data = json.loads(out.decode().strip().splitlines()[-1])
            if code or "event" in data:
                raise ValueError(data.get("message", "music inventory failed"))
            self.version = data.get("version")
            self.models = sorted(data.get("models", []))
            self.extra_info = {"catalog": list(MODELS)}
            self._refreshed_at = time.monotonic()
        except Exception as exc:
            LOG.warning("couldn't read music inventory: %s", exc)
        finally:
            await probe.stop()

    async def repos_for(self, model: str) -> list[str]:
        if model not in MODELS:
            raise ValueError(f"unknown music model: {model}")
        return [MODELS[model]["repo"]]

    def download_argv(self, model: str) -> list[str]:
        if model not in MODELS:
            raise ValueError(f"unknown music model: {model}")
        return [*self.worker_argv, "--download", model]

    async def execute(self, ctx: JobContext, workflow: Any, *, timeout_s: int, progress: ProgressFn) -> list[dict]:
        self.validate(workflow)
        output = self.job_dir(ctx) / f"music_{ctx.job_id}.wav"
        state = {"loaded": False, "done": False, "error": None, "stage": "running"}

        def on_line(line: str) -> None:
            try:
                event = json.loads(line)
            except ValueError:
                if line.startswith("[abc]"):
                    state["stage"] = "composing_score"
                elif line.startswith("[semantic]"):
                    state["stage"] = "generating_music"
                elif line.startswith("[nar]"):
                    state["stage"] = "refining_audio"
                elif line.startswith("[vae]"):
                    state["stage"] = "decoding_audio"
                return
            if not isinstance(event, dict):
                return
            if event.get("event") == "loaded":
                state["loaded"] = True
            elif event.get("event") == "done":
                state["done"] = True
            elif event.get("event") == "error":
                state["error"] = event.get("message") or "music generation failed"

        self.process = ChildProcess("MLX music", on_line=on_line)
        ctx.timings.mark_prompt()
        ctx.phase = "loading_model"
        deadline = time.monotonic() + self.config.mlx_load_timeout_s
        wait = None
        try:
            await self.process.start([*self.worker_argv, "--generate", "--output", str(output)],
                                     stdin=True, merged=True)
            self.process.proc.stdin.write(json.dumps(workflow).encode())
            await self.process.proc.stdin.drain()
            self.process.proc.stdin.close()
            await progress(ctx, "loading_model", 0.0)
            wait = asyncio.create_task(self.process.wait())
            while True:
                if ctx.cancel_requested:
                    raise JobCancelled()
                if state["loaded"] and ctx.phase == "loading_model":
                    ctx.phase = "running"
                    ctx.timings.mark_execution_start()
                    deadline = time.monotonic() + timeout_s
                if time.monotonic() >= deadline:
                    reason = "music generation timed out" if state["loaded"] else "music model loading timed out"
                    raise JobError("execute", reason)
                if state["error"]:
                    raise JobError("execute", state["error"])
                # No invented percentage: MiniMax has no reliable per-step progress callback.
                await progress(ctx, "running" if state["loaded"] else "loading_model", 0.0,
                               node=state["stage"] if state["loaded"] else "loading_model")
                done, _ = await asyncio.wait({wait}, timeout=0.5)
                if done:
                    break
            if ctx.cancel_requested:
                raise JobCancelled()
            if wait.result() != 0 or not state["done"]:
                raise JobError("execute", state["error"] or f"music worker stopped: {self.process.tail()}")
            ctx.timings.mark_execution_end()
            return self.outputs(ctx, output)
        finally:
            await self.process.stop()
            if wait and not wait.done():
                await wait
            self._refreshed_at = None

    async def cancel(self, ctx: JobContext) -> bool:
        await self.free_memory()
        return False

    async def free_memory(self) -> None:
        if self.process:
            await self.process.stop()

    async def close(self) -> None:
        await self.free_memory()
