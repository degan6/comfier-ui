"""Native MLX music, currently the tested MiniMax Music 3 BF16 pipeline."""

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
from comfier_agent.workers.minimax_music import MODEL, validate

LOG = logging.getLogger("comfier_agent")
POLL_S = 0.5


def default_worker_argv() -> list[str]:
    return [sys.executable, "-m", "comfier_agent.workers.minimax_music"]


class MlxAudioEngine(MlxEngine):
    name = "mlx_audio"
    command = re.compile(r"^minimax-music3$")

    def __init__(self, config, runner_argv: list[str] | None = None):
        super().__init__(config)
        self.runner_argv = runner_argv or default_worker_argv()
        self.process: ChildProcess | None = None
        self.ready = False

    async def refresh(self) -> None:
        if self._refreshed_at and time.monotonic() - self._refreshed_at < 600:
            return
        probe = ChildProcess("MLX audio inventory")
        try:
            await probe.start([*self.runner_argv, "--probe"], stdout=True)
            out = await asyncio.wait_for(probe.proc.stdout.read(), 120)
            code = await probe.wait()
            if code:
                raise ValueError(probe.tail())
            data = json.loads(out.decode().strip().splitlines()[-1])
            self.version = data.get("version")
            self.ready = bool(self.version)
            self.models = sorted(data.get("models") or [])
            self.extra_info = {"catalog": data.get("catalog") or [], "revision": data.get("revision"),
                               "runtime_error": data.get("error")}
            self._refreshed_at = time.monotonic()
        except Exception as exc:
            self.ready = False
            self.version = None
            self.models = []
            self.extra_info = {"runtime_error": str(exc)}
            LOG.warning("couldn't read MLX audio's runtime: %s", exc)
        finally:
            await probe.stop()

    def validate(self, workflow: Any) -> None:
        super().validate(workflow)
        try:
            validate(workflow)
        except ValueError as exc:
            raise JobError("validate", str(exc)) from exc

    async def execute(self, ctx: JobContext, workflow: Any, *, timeout_s: int, progress: ProgressFn) -> list[dict]:
        folder = self.job_dir(ctx)
        request = folder / "request.json"
        request.write_text(json.dumps(workflow))
        out = folder / f"mlx_audio_{ctx.job_id}.wav"
        state = {"loaded": False}

        def on_line(line: str) -> None:
            try:
                event = json.loads(line)
            except ValueError:
                return
            if event.get("event") == "loaded":
                state["loaded"] = True
            elif event.get("event") == "done":
                LOG.info("MiniMax generation: %s", line)

        self.process = ChildProcess("MLX audio", on_line=on_line)
        ctx.timings.mark_prompt()
        ctx.phase = "loading_model"
        await progress(ctx, "loading_model", 0.0)
        deadline = time.monotonic() + self.config.mlx_load_timeout_s
        try:
            await self.process.start([*self.runner_argv, "--request", str(request), "--output", str(out)], merged=True)
            wait = asyncio.ensure_future(self.process.wait())
            try:
                while not wait.done():
                    if ctx.cancel_requested:
                        raise JobCancelled()
                    if state["loaded"] and ctx.phase != "running":
                        ctx.phase = "running"
                        ctx.timings.mark_execution_start()
                        deadline = time.monotonic() + timeout_s
                    if time.monotonic() >= deadline:
                        reason = "timeout" if ctx.phase == "running" else "loading the model took too long"
                        raise JobError("execute", reason)
                    # MiniMax has no reliable fraction; don't turn elapsed time into a percentage.
                    await progress(ctx, ctx.phase, 0.0)
                    await asyncio.wait({wait}, timeout=POLL_S)
                if ctx.cancel_requested:
                    raise JobCancelled()
                if wait.result():
                    raise JobError("execute", f"MLX audio exited with code {wait.result()}: {self.process.tail()}",
                                   traceback_tail=self.process.tail(30))
            finally:
                if not wait.done():
                    wait.cancel()
        finally:
            await self.process.stop()
            self._refreshed_at = None
        ctx.timings.mark_execution_end()
        outputs = self.outputs(ctx, out)
        if out.with_suffix(".mp3").is_file():
            outputs += self.outputs(ctx, out.with_suffix(".mp3"))
        return outputs

    def download_argv(self, model: str) -> list[str]:
        if model != MODEL:
            raise ValueError(f"unsupported MiniMax model {model!r}")
        return [*self.runner_argv, "--download", model]

    async def repos_for(self, model: str) -> list[str]:
        return [MODEL] if model == MODEL else []

    async def cancel(self, ctx: JobContext) -> bool:
        if self.process:
            await self.process.stop()
        return False

    async def close(self) -> None:
        if self.process:
            await self.process.stop()
