"""Pinned YuE2 MLX pipeline, isolated from the agent and other audio runtimes."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import math
import os
import shutil
import tempfile
import time
from pathlib import Path

from comfier_agent.workers.minimax_music import emit

MODEL = "vanch007/mlx-Yue2-3B"
REVISION = "5f7620e546fb3c6130a09a7e18172e3bb7aaeddb"
SAMPLING_DEFAULTS = {
    "abc": {"temperature": .7, "top_p": .9, "top_k": 30, "repetition_penalty": 1.005,
            "penalty_window": 100, "min_tokens": 32, "max_tokens": 4096},
    "semantic": {"temperature": 1., "top_p": .95, "top_k": 100, "repetition_penalty": 1.2,
                 "penalty_window": 50, "min_tokens": 200, "max_tokens": 9000},
}
SAMPLING_OPTIONS = {f"{stage}_{key}" for stage, defaults in SAMPLING_DEFAULTS.items() for key in defaults}
SAMPLING_RANGES = {"temperature": (0, 5), "top_p": (0, 1), "top_k": (1, math.inf),
                   "repetition_penalty": (0, math.inf), "penalty_window": (1, 100),
                   "min_tokens": (0, 24575), "max_tokens": (1, 24575)}
SAMPLING_INTEGERS = {"top_k", "penalty_window", "min_tokens", "max_tokens"}
OPTIONS = {"command", "model", "style", "lyrics", "duration", "steps", "seed", "min_memory_gb",
           "precision", "cot", "abc", "cfg_scale", *SAMPLING_OPTIONS}
# The BF16 AR is needed for acoustic conditioning even when planning uses 8-bit weights.
FILES = {"conversion.json", "config.json", "qwen.tiktoken", "ar-8bit.safetensors", "ar-bf16.safetensors",
         "nar-bf16.safetensors", "LICENSE", "THIRD_PARTY_NOTICES.md", "licenses/SnakeBeta-NVIDIA-MIT.txt",
         "licenses/stable-audio-tools-MIT.txt", "vae/config.json", "vae/model.safetensors",
         "vae/weights_manifest.json"}


def validate(recipe: dict) -> None:
    if not isinstance(recipe, dict) or recipe.get("command") != "yue2":
        raise ValueError("YuE2 needs command yue2")
    if recipe.get("model") != MODEL:
        raise ValueError(f"YuE2 needs model {MODEL}")
    unknown = recipe.keys() - OPTIONS
    if unknown:
        raise ValueError(f"unsupported YuE2 option: {sorted(unknown)[0]}")
    for key in ("style", "lyrics"):
        if not isinstance(recipe.get(key), str) or not recipe[key].strip():
            raise ValueError(f"YuE2 needs {key}; use [Instrumental] for lyrics without vocals")
    for key, low, high in (("duration", .04, 360), ("steps", 1, 64), ("seed", 0, 2**32 - 1)):
        value = recipe.get(key)
        if (isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
                or not low <= value <= high or (key != "duration" and not isinstance(value, int))):
            kind = "an integer" if key != "duration" else "a number"
            raise ValueError(f"{key} must be {kind} between {low} and {high}")
    if recipe.get("precision", "8bit") not in ("8bit", "bf16"):
        raise ValueError("precision must be 8bit or bf16")
    if recipe.get("cot", "full") not in ("full", "melody", "off"):
        raise ValueError("cot must be full, melody or off")
    if "abc" in recipe and (recipe.get("cot", "full") == "off" or not isinstance(recipe["abc"], str)
                            or not recipe["abc"].strip()):
        raise ValueError("abc needs nonempty notation and cot full or melody")
    if "cfg_scale" in recipe:
        value = recipe["cfg_scale"]
        if (isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
                or not 0 <= value <= 20):
            raise ValueError("cfg_scale must be a number between 0 and 20")

    sampling_settings(recipe)


def sampling_settings(recipe: dict) -> dict:
    """Resolve literal workflow controls without importing the optional MLX runtime."""
    limit = max(1, int(recipe["duration"] * 25))
    stages = {}
    for stage, defaults in SAMPLING_DEFAULTS.items():
        values = {key: recipe.get(f"{stage}_{key}", value) for key, value in defaults.items()}
        if stage == "semantic":
            values["max_tokens"] = recipe.get("semantic_max_tokens", limit)
            if "semantic_max_tokens" in recipe:
                validate_sampling_value("semantic_max_tokens", values["max_tokens"])
                if values["max_tokens"] > limit:
                    raise ValueError("semantic_max_tokens cannot exceed duration * 25")
            if "semantic_min_tokens" not in recipe:
                values["min_tokens"] = min(200, values["max_tokens"])
        for key, value in values.items():
            validate_sampling_value(f"{stage}_{key}", value)
        if values["min_tokens"] > values["max_tokens"]:
            raise ValueError(f"{stage}_min_tokens cannot exceed {stage}_max_tokens")
        stages[stage] = values
    return stages


def validate_sampling_value(name: str, value) -> None:
    key = name.split("_", 1)[1]
    low, high = SAMPLING_RANGES[key]
    if (isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
            or not low <= value <= high or (low == 0 and key in {"top_p", "repetition_penalty"} and value == 0)
            or (key in SAMPLING_INTEGERS and not isinstance(value, int))):
        kind = "an integer" if key in SAMPLING_INTEGERS else "a finite number"
        bounds = (f"greater than {low} and at most {high}" if key in {"top_p", "repetition_penalty"}
                  else f"in [{low}, {high}]")
        raise ValueError(f"{name} must be {kind} {bounds}; use a literal JSON value")


def complete_snapshot(path: Path) -> bool:
    try:
        manifest = json.loads((path / "conversion.json").read_text())
        if not all((path / name).is_file() and (path / name).stat().st_size > 0 for name in FILES):
            return False
        vae = json.loads((path / "vae/weights_manifest.json").read_text())
        return (all((path / name).stat().st_size == info["bytes"] for name, info in manifest["files"].items())
                and all((path / "vae" / name).stat().st_size == info["bytes"] for name, info in vae["files"].items()))
    except (OSError, KeyError, TypeError, ValueError):
        return False


def model_path(*, offline: bool = False) -> Path:
    from huggingface_hub import snapshot_download

    options = {"repo_id": MODEL, "revision": REVISION, "allow_patterns": sorted(FILES | {"vae/*", "vae/licenses/*"})}
    try:
        cached = Path(snapshot_download(**options, local_files_only=True))
        if complete_snapshot(cached):
            return cached
    except Exception:  # noqa: BLE001 - no complete local revision yet
        pass
    if offline or os.environ.get("HF_HUB_OFFLINE", "").lower() in {"1", "true", "yes", "on"}:
        raise ValueError("YuE2's pinned model is incomplete; download it before running offline")
    path = Path(snapshot_download(**options))
    if not complete_snapshot(path):
        raise ValueError("YuE2 model download is incomplete")
    return path


def probe() -> dict:
    try:
        version = importlib.metadata.version("mlx-yue")
        from lyra import YuE2Pipeline  # noqa: F401 - check the API without loading weights
        from lyra.runtime import require_supported_runtime
        require_supported_runtime()
    except Exception as exc:  # noqa: BLE001 - broken or missing optional native runtime
        return {"models": [], "catalog": [MODEL], "error": f"YuE2 runtime unavailable: {exc}"}
    try:
        cached = complete_snapshot(model_path(offline=True))
    except Exception:  # noqa: BLE001 - missing weights aren't a ready model
        cached = False
    return {"version": version, "models": [MODEL] if cached else [], "catalog": [MODEL], "revision": REVISION}


def materialize(snapshot: Path, target: Path) -> None:
    # YuE2 verifies a conversion and rejects symlinks. Hub snapshots use symlinks, so give the pipeline
    # regular hardlinks to the immutable blobs, falling back to copies across filesystems.
    for name in FILES:
        source = snapshot / name
        dest = target / name if name.startswith("vae/") else target / "generator" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(source.resolve(), dest)
        except OSError:
            shutil.copyfile(source, dest)


def generate(recipe: dict, output: Path) -> None:
    validate(recipe)
    import numpy as np
    import soundfile as sf
    from lyra import GenerationConfig, Sampling, YuE2Pipeline

    emit("loading")
    started = time.perf_counter()
    snapshot = model_path()
    output.parent.mkdir(parents=True, exist_ok=True)
    sampling = sampling_settings(recipe)
    config = GenerationConfig(ode_steps=recipe["steps"], abc=Sampling(**sampling["abc"]),
                              semantic=Sampling(**sampling["semantic"]))
    with tempfile.TemporaryDirectory(prefix="yue2-", dir=output.parent) as directory:
        model = Path(directory)
        materialize(snapshot, model)
        with YuE2Pipeline.from_pretrained(str(model / "generator"), vae=str(model / "vae"),
                                         precision=recipe.get("precision", "8bit"), local_files_only=True,
                                         generation_config=config, progress=False) as pipe:
            # The pinned pipeline loads lazily; include the initial AR load in the model-load timeout.
            pipe._load_model()
            loaded = time.perf_counter()
            emit("loaded")
            result = pipe(style=recipe["style"], lyrics=recipe["lyrics"], seed=recipe["seed"],
                          cot=recipe.get("cot", "full"),
                          **{key: recipe[key] for key in ("abc", "cfg_scale") if key in recipe})
            audio = np.asarray(result.audio)
            if (audio.ndim != 2 or audio.shape[0] == 0 or audio.shape[1] != 2
                    or not np.isfinite(audio).all() or result.sample_rate != 48000):
                raise ValueError("YuE2 produced invalid or empty 48 kHz stereo audio")
            sf.write(str(output), audio, result.sample_rate, subtype="PCM_24")
            emit("done", model=MODEL, revision=REVISION, runtime_version=importlib.metadata.version("mlx-yue"),
                 load_seconds=loaded - started, generation_seconds=time.perf_counter() - loaded,
                 sample_rate=result.sample_rate, duration_seconds=len(audio) / result.sample_rate,
                 requested_seconds=recipe["duration"], steps=recipe["steps"], seed=recipe["seed"],
                 precision=recipe.get("precision", "8bit"), cot=recipe.get("cot", "full"),
                 cfg_scale=recipe.get("cfg_scale", 1.01 if recipe.get("cot", "full") == "off" else 1.),
                 abc_sampling=sampling["abc"], semantic_sampling=sampling["semantic"])


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
                raise ValueError(f"unsupported YuE2 model {args.download!r}")
            emit("repo", repo=MODEL)
            model_path()
            emit("done")
        except Exception as exc:  # noqa: BLE001 - agent download protocol
            emit("error", message=f"{type(exc).__name__}: {exc}")
            raise SystemExit(1) from exc
    else:
        if args.output is None:
            parser.error("--request requires --output")
        generate(json.loads(args.request.read_text()), args.output)


if __name__ == "__main__":
    main()
