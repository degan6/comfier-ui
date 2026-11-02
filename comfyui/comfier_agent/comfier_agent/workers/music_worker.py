"""One native music job per process. No Studio server or UI is needed.

YuE2's inference modules come from the explicitly pinned community model snapshot;
MiniMax uses the pinned mlx-audio dependency. JSON events share stdout with upstream logs.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import secrets
import sys
import wave
from dataclasses import replace
from pathlib import Path

from comfier_agent.music_models import MODELS, complete_snapshot, validate_recipe


def emit(event: str, **data) -> None:
    print(json.dumps({"event": event, **data}), flush=True)


def snapshot(model: str, *, local: bool = False) -> Path:
    from huggingface_hub import snapshot_download

    spec = MODELS[model]
    path = Path(snapshot_download(repo_id=spec["repo"], revision=spec["revision"],
                                  allow_patterns=spec["patterns"], local_files_only=local))
    if not complete_snapshot(path, model):
        raise ValueError(f"{model}: model download is incomplete; download it again")
    return path


def inventory() -> dict:
    from importlib.metadata import version

    models = []
    for model in MODELS:
        try:
            snapshot(model, local=True)
        except (OSError, ValueError):
            continue
        models.append(model)
    return {"models": models, "version": version("mlx-audio")}


def run_yue(path: Path, recipe: dict, output: Path) -> None:
    # This modifies only the short-lived worker, never the agent's import path. The
    # exact source revision is pinned alongside the weights in music_models.py.
    sys.path.insert(0, str(path))
    spec = importlib.util.spec_from_file_location("comfier_yue2_generate", path / "generate.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    pipe = module.Yue2Pipeline(path / "8bit", log=lambda line: print(line, flush=True))
    emit("loaded")
    seconds = recipe.get("duration", 30)
    sampling = replace(pipe.semantic_sampling, max_tokens=round(seconds * 25),
                       min_tokens=min(pipe.semantic_sampling.min_tokens, round(seconds * 25)))
    audio, _ = pipe(recipe["prompt"], recipe["lyrics"], cot=recipe.get("planning", "off"),
                    seed=recipe["seed"], steps=recipe.get("steps", 32), semantic_sampling=sampling)
    module.write_wav(output, audio)


def run_minimax(path: Path, recipe: dict, output: Path) -> None:
    import numpy as np
    from mlx_audio.audio_io import write
    from mlx_audio.music import load

    model = load(str(path))
    emit("loaded")
    result = next(model.generate(text=recipe["prompt"], lyrics=recipe["lyrics"],
                                duration=recipe.get("duration", 30), steps=recipe.get("steps", 30),
                                seed=recipe["seed"]))
    audio = np.asarray(result.audio)
    if audio.size == 0 or not np.isfinite(audio).all():
        raise ValueError("MiniMax produced invalid audio")
    write(output, result.audio, result.sample_rate)


def generate(recipe: dict, output: Path) -> None:
    validate_recipe(recipe)
    recipe = dict(recipe)
    recipe.setdefault("seed", secrets.randbelow(2**32))
    if not recipe.get("lyrics", "").strip():
        recipe["lyrics"] = "[Instrumental]"
        recipe["prompt"] += ", instrumental, no vocals"
    path = snapshot(recipe["model"])
    output.parent.mkdir(parents=True, exist_ok=True)
    (run_yue if recipe["model"] == "yue2" else run_minimax)(path, recipe, output)
    with wave.open(str(output), "rb") as audio:
        if not audio.getnframes() or audio.getnchannels() != 2:
            raise ValueError("music worker did not produce nonempty stereo WAV audio")
    emit("done")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--inventory", action="store_true")
    action.add_argument("--download", choices=list(MODELS))
    action.add_argument("--generate", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.inventory:
            print(json.dumps(inventory()), flush=True)
        elif args.download:
            emit("repo", repo=MODELS[args.download]["repo"])
            snapshot(args.download)
            emit("done")
        else:
            if args.output is None:
                raise ValueError("--output is required for generation")
            generate(json.load(sys.stdin), args.output)
    except Exception as exc:
        emit("error", message=f"{type(exc).__name__}: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
