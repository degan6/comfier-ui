"""Pinned native music models. No MLX imports: inventory and validation run on the agent loop."""

from __future__ import annotations

import json
import math
from pathlib import Path

MODELS = {
    "yue2": {
        "repo": "ahmadw/YuE2-3B-MLX",
        "revision": "fe0a9050fd658257b486b880422d8872ee1f81e3",
        "patterns": ["generate.py", "yue2_model.py", "yue2_vae.py", "8bit/*", "README.md", "LICENSE*"],
        "min_memory_gb": 32,
    },
    "minimax-music3": {
        "repo": "mlx-community/MiniMax-Music3-bf16",
        "revision": "83a5f2d365673689df5c8f36e21e108751fd92ea",
        "patterns": ["*.safetensors", "*.json", "*.model", "*.txt", "*.jinja", "README.md", "LICENSE*"],
        "min_memory_gb": 96,
    },
}
OPTIONS = {"command", "model", "prompt", "lyrics", "duration", "steps", "seed", "planning", "min_memory_gb"}


def validate_recipe(recipe: dict) -> None:
    if set(recipe) - OPTIONS:
        raise ValueError(f"unknown music options: {', '.join(sorted(set(recipe) - OPTIONS))}")
    model = recipe.get("model")
    if not isinstance(model, str) or model not in MODELS:
        raise ValueError("music model must be yue2 or minimax-music3")
    if not isinstance(recipe.get("prompt"), str) or not 3 <= len(recipe["prompt"].strip()) <= 2000:
        raise ValueError("music prompt must have 3–2000 characters")
    if not isinstance(recipe.get("lyrics", ""), str) or len(recipe.get("lyrics", "")) > 6000:
        raise ValueError("lyrics must be text, at most 6000 characters")
    duration = recipe.get("duration", 30)
    limit = 300 if model == "minimax-music3" else 360
    if type(duration) not in (int, float) or not math.isfinite(duration) or not 1 <= duration <= limit:
        raise ValueError(f"duration must be from 1 to {limit} seconds")
    for key, default, low, high in (
        ("steps", 30 if model == "minimax-music3" else 32, 1, 30 if model == "minimax-music3" else 256),
        ("seed", 0, 0, 4294967295),
    ):
        value = recipe.get(key, default)
        if type(value) is not int or not low <= value <= high:
            raise ValueError(f"{key} must be an integer from {low} to {high}")
    planning = recipe.get("planning", "off")
    if planning not in ("off", "melody", "full") or (model == "minimax-music3" and planning != "off"):
        raise ValueError("score planning is off, melody or full, and is YuE2-only")


def complete_snapshot(path: Path, model: str) -> bool:
    if model == "yue2":
        files = ["generate.py", "yue2_model.py", "yue2_vae.py", *(
            "8bit/" + name for name in ("model.safetensors", "vae.safetensors", "config.json",
                                        "vae_config.json", "qwen.tiktoken", "yue2_generation_config.json"))]
    else:
        try:
            shards = set(json.loads((path / "model.safetensors.index.json").read_text())["weight_map"].values())
            # The index must not reference files outside this snapshot.
            if not shards or any(Path(name).name != name for name in shards):
                return False
        except (OSError, ValueError, KeyError, TypeError):
            return False
        files = [*shards, "config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"]
    return all((path / name).is_file() and (path / name).stat().st_size > 0 for name in files)
