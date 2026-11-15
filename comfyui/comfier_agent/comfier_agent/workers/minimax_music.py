"""The tested MiniMax Music 3 MLX runtime, isolated from the agent and its other engines."""

from __future__ import annotations

import argparse
import contextlib
import importlib.metadata
import json
import math
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

MODEL = "mlx-community/MiniMax-Music3-bf16"
REVISION = "83a5f2d365673689df5c8f36e21e108751fd92ea"
PATTERNS = ["*.safetensors", "*.json", "*.txt", "*.model", "*.jinja"]
DEFAULT_CONTROLS = {"semantic_guidance": 1.5, "acoustic_guidance": 1.7, "top_k": 50}
OPTIONS = {"command", "model", "caption", "lyrics", "duration", "steps", "seed", "min_memory_gb", *DEFAULT_CONTROLS}


def validate(recipe: dict) -> None:
    if not isinstance(recipe, dict) or recipe.get("command") != "minimax-music3":
        raise ValueError("MLX audio needs command minimax-music3")
    if recipe.get("model") != MODEL:
        raise ValueError(f"MiniMax needs model {MODEL}")
    unknown = recipe.keys() - OPTIONS
    if unknown:
        raise ValueError(f"unsupported MiniMax option: {sorted(unknown)[0]}")
    for key in ("caption", "lyrics"):
        if not isinstance(recipe.get(key), str) or not recipe[key].strip():
            raise ValueError(f"MiniMax needs {key}; use [Instrumental] for lyrics without vocals")
    for key, low, high in (("duration", 0.04, 300), ("steps", 1, 30), ("seed", 0, 2**32 - 1),
                          ("semantic_guidance", 0, 10), ("acoustic_guidance", 0, 10), ("top_k", 1, 16384)):
        value = recipe.get(key, DEFAULT_CONTROLS.get(key))
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"{key} must be a number between {low} and {high}")
        integral = key in {"steps", "seed", "top_k"}
        if not low <= value <= high or (integral and not isinstance(value, int)):
            kind = "an integer" if integral else "a number"
            raise ValueError(f"{key} must be {kind} between {low} and {high}")


def model_path(*, offline: bool = False) -> Path:
    from huggingface_hub import snapshot_download

    options = {"repo_id": MODEL, "revision": REVISION, "allow_patterns": PATTERNS}
    try:
        cached = Path(snapshot_download(**options, local_files_only=True))
        if offline or complete_snapshot(cached):
            return cached
    except Exception:  # noqa: BLE001 - no local revision yet; an online job may download it
        if offline:
            raise
    if os.environ.get("HF_HUB_OFFLINE", "").lower() in {"1", "true", "yes", "on"}:
        raise ValueError("MiniMax's pinned model is incomplete; download it before running offline")
    return Path(snapshot_download(**options))


def complete_snapshot(path: Path) -> bool:
    """A partial download isn't a ready model. Every shard and the real tokenizer must be present."""
    try:
        index = json.loads((path / "model.safetensors.index.json").read_text())
        required = {"config.json", "tokenizer/tokenizer.json", *index["weight_map"].values()}
        return all((path / name).is_file() and (path / name).stat().st_size > 0 for name in required)
    except (OSError, KeyError, ValueError):
        return False


def probe() -> dict:
    try:
        version = importlib.metadata.version("mlx-audio")
        from mlx_audio.audio_io import write  # noqa: F401 - verify the native API without loading weights
        from mlx_audio.music.models.minimax_music3.minimax_music3 import Model  # noqa: F401
    except Exception as exc:  # noqa: BLE001 - missing MiniMax support or a broken native library
        return {"models": [], "catalog": [MODEL], "error": f"MiniMax runtime unavailable: {exc}"}
    try:
        cached = complete_snapshot(model_path(offline=True))
    except Exception:  # noqa: BLE001 - a missing cache or revision is not a ready model
        cached = False
    return {"version": version, "models": [MODEL] if cached else [], "catalog": [MODEL], "revision": REVISION}


def emit(event: str, **extra) -> None:
    print(json.dumps({"event": event, **extra}), flush=True)


@contextlib.contextmanager
def generation_controls(recipe: dict):
    # The pinned runtime ignores extra generate() kwargs. These globals are read by its AR and flow
    # stages; only this isolated job process changes them, and restores them on success or failure.
    ar = importlib.import_module("mlx_audio.music.models.minimax_music3.ar")
    pipeline = importlib.import_module("mlx_audio.music.models.minimax_music3.minimax_music3")
    controls = {key: recipe.get(key, default) for key, default in DEFAULT_CONTROLS.items()}
    previous = ar.AR_CFG_SCALE, ar.AR_CFG_TOP_K, ar.AR_SAMPLING_TOP_K, pipeline.DIT_CFG_SCALE
    ar.AR_CFG_SCALE = controls["semantic_guidance"]
    ar.AR_CFG_TOP_K = ar.AR_SAMPLING_TOP_K = controls["top_k"]
    pipeline.DIT_CFG_SCALE = controls["acoustic_guidance"]
    try:
        yield controls
    finally:
        ar.AR_CFG_SCALE, ar.AR_CFG_TOP_K, ar.AR_SAMPLING_TOP_K, pipeline.DIT_CFG_SCALE = previous


def generate(recipe: dict, output: Path) -> None:
    validate(recipe)
    import mlx.core as mx
    import numpy as np
    from mlx_audio.audio_io import write
    from mlx_audio.music import load

    emit("loading")
    started = time.perf_counter()
    model = load(str(model_path()))
    loaded = time.perf_counter()
    done = threading.Event()

    def heartbeat() -> None:
        while not done.wait(30):
            emit("heartbeat", elapsed_seconds=round(time.perf_counter() - loaded))

    threading.Thread(target=heartbeat, daemon=True).start()
    try:
        with generation_controls(recipe) as controls:
            emit("loaded", **controls)
            result = next(model.generate(text=recipe["caption"], lyrics=recipe["lyrics"], duration=recipe["duration"],
                                         steps=recipe["steps"], seed=recipe["seed"]))
        audio = np.asarray(result.audio)
        if audio.ndim != 2 or audio.shape[0] == 0 or audio.shape[1] != 2 or not np.isfinite(audio).all():
            raise ValueError("MiniMax produced invalid or empty stereo audio")
        rate = result.sample_rate
        if isinstance(rate, bool) or not isinstance(rate, int) or rate <= 0:
            raise ValueError("MiniMax produced an invalid sample rate")
        emit("saving")
        output.parent.mkdir(parents=True, exist_ok=True)
        write(output, result.audio, rate)
        metrics = {"model": MODEL, "revision": REVISION, "runtime_version": importlib.metadata.version("mlx-audio"),
                   "mlx_version": importlib.metadata.version("mlx"), "load_seconds": loaded - started,
                   "generation_seconds": time.perf_counter() - loaded, "peak_mlx_gb": mx.get_peak_memory() / 1e9,
                   "sample_rate": rate, "duration_seconds": len(audio) / rate,
                   "requested_seconds": recipe["duration"], "steps": recipe["steps"], "seed": recipe["seed"],
                   **controls}
        output.with_suffix(".metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
        # WAV is the master; a missing/failed encoder never loses the recording.
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg:
            mp3 = output.with_suffix(".mp3")
            try:
                subprocess.run([ffmpeg, "-v", "error", "-y", "-i", str(output), "-c:a", "libmp3lame", "-q:a", "0",
                                str(mp3)], check=True, timeout=300)
            except (OSError, subprocess.SubprocessError) as exc:
                mp3.unlink(missing_ok=True)
                print(f"MP3 export failed; keeping WAV: {exc}", flush=True)
        emit("done", **metrics)
    finally:
        done.set()


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--probe", action="store_true")
    mode.add_argument("--download")
    mode.add_argument("--request", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.probe:
        print(json.dumps(probe()))
    elif args.download:
        try:
            if args.download != MODEL:
                raise ValueError(f"unsupported MiniMax model {args.download!r}")
            emit("repo", repo=MODEL)
            if not complete_snapshot(model_path()):
                raise ValueError("MiniMax model download is incomplete")
            emit("done")
        except Exception as exc:  # noqa: BLE001 - downloads report failures to the agent as JSON
            emit("error", message=f"{type(exc).__name__}: {exc}")
            raise SystemExit(1) from exc
    else:
        if args.output is None:
            parser.error("--request requires --output")
        generate(json.loads(args.request.read_text()), args.output)


if __name__ == "__main__":
    main()
