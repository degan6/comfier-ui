"""Route native audio jobs and probe each optional runtime in a separate process."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from comfier_agent.workers import minimax_music, yue2

WORKERS = {"minimax-music3": minimax_music, "yue2": yue2}
MODELS = {worker.MODEL: worker for worker in WORKERS.values()}


def yue2_python() -> str:
    configured = os.environ.get("COMFIER_YUE2_PYTHON")
    if configured:
        return os.path.expanduser(configured)
    isolated = Path("~/.comfier/yue2/bin/python").expanduser()
    return str(isolated) if isolated.is_file() else sys.executable


def yue2_installed() -> bool:
    """Whether YuE2 has an interpreter of its own, apart from the agent's."""
    python = yue2_python()
    return python != sys.executable and bool(shutil.which(python))


def worker_argv(worker) -> list[str]:
    python = yue2_python() if worker is yue2 else sys.executable
    return [python, "-m", worker.__name__]


def validate(recipe: dict) -> None:
    worker = WORKERS.get(recipe.get("command")) if isinstance(recipe, dict) else None
    if worker is None:
        raise ValueError("MLX audio needs command minimax-music3 or yue2")
    worker.validate(recipe)


def probe() -> dict:
    runtimes = {}
    for command, worker in WORKERS.items():
        try:
            child = subprocess.run([*worker_argv(worker), "--probe"],
                                   capture_output=True, text=True, timeout=45, check=True)
            runtimes[command] = json.loads(child.stdout.strip().splitlines()[-1])
        except (OSError, ValueError, IndexError, subprocess.SubprocessError) as exc:
            runtimes[command] = {"error": str(exc), "models": [], "catalog": [worker.MODEL]}
    ready = [data for data in runtimes.values() if data.get("version")]
    return {"version": ", ".join(data["version"] for data in ready) or None,
            "models": sorted({model for data in ready for model in data.get("models", [])}),
            "catalog": sorted(MODELS), "runtimes": runtimes,
            "error": None if ready else "; ".join(data.get("error", "unavailable") for data in runtimes.values())}


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--probe", action="store_true")
    mode.add_argument("--download", choices=MODELS)
    mode.add_argument("--request", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.probe:
        print(json.dumps(probe()))
    elif args.download:
        argv = [*worker_argv(MODELS[args.download]), "--download", args.download]
        os.execv(argv[0], argv)
    else:
        if args.output is None:
            parser.error("--request requires --output")
        recipe = json.loads(args.request.read_text())
        validate(recipe)
        argv = [*worker_argv(WORKERS[recipe["command"]]), "--request", str(args.request), "--output", str(args.output)]
        os.execv(argv[0], argv)


if __name__ == "__main__":
    main()
