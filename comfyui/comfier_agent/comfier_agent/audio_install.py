"""Install MiniMax's isolated runtime without changing image/video dependencies."""

from __future__ import annotations

import json
import platform
import shutil
import subprocess

from comfier_agent.config import comfier_home, default_config_path, load_config, save_config
from comfier_agent.engines.mlx import child_env
from comfier_agent.gpu_lock import GpuLock

AUDIO_REQUIREMENTS = [
    "mlx==0.32.2",
    "mlx-audio @ git+https://github.com/Blaizzy/mlx-audio.git@784b29e2691a93ca7483147d86f61859dfaa6296",
]


def install_audio() -> int:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        print("MLX audio requires an Apple Silicon Mac.")
        return 1
    uv = shutil.which("uv")
    if not uv:
        print("Install uv first: brew install uv. Then run comfier-agent install audio again.")
        return 1
    config = load_config(sidecar=True)
    path = config.config_path or default_config_path()
    # Don't let save_config replace a malformed settings file and lose the server key.
    try:
        settings = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(settings, dict):
            raise ValueError("expected a JSON object")
        if settings.get("engines") is not None and (
            not isinstance(settings["engines"], list)
            or not all(isinstance(engine, str) for engine in settings["engines"])
        ):
            raise ValueError("engines must be a list of engine names")
    except (OSError, ValueError) as exc:
        print(f"Cannot read {path}: {exc}. Fix the configuration before installing audio.")
        return 1

    runtime = comfier_home().resolve() / "audio"
    python = runtime / "bin" / "python"
    if python.exists() and not config.gpu_lock:
        print("Updating an existing audio runtime requires GPU coordination. Enable gpu_lock and retry.")
        return 1
    lock = GpuLock(config.gpu_lock_path, enabled=config.gpu_lock)
    print("Installing MiniMax audio. Waiting for the current Comfier GPU job to finish if needed…", flush=True)
    try:
        lock.acquire(wait=True)
        if not python.exists():
            subprocess.run([uv, "venv", "--python", "3.12", str(runtime)], check=True)
        subprocess.run([uv, "pip", "install", "--python", str(python), *AUDIO_REQUIREMENTS], check=True)
        print("Checking the MiniMax runtime (no model download)…", flush=True)
        result = subprocess.run(
            [str(python), "-m", "comfier_agent.workers.minimax_music", "--probe"],
            env=child_env(), capture_output=True, text=True, check=True, timeout=120,
        )
        probe = json.loads(result.stdout.strip().splitlines()[-1])
        if not probe.get("version") or probe.get("error"):
            raise ValueError(probe.get("error") or "runtime did not report a version")
        updates = {"mlx_audio_python": str(python)}
        if settings.get("engines") is not None:
            updates["engines"] = list(dict.fromkeys([*settings["engines"], "mlx_audio"]))
        save_config(config, updates)
    except (OSError, subprocess.SubprocessError, ValueError, IndexError) as exc:
        print(f"Audio installation failed: {exc}. Configuration was not changed; retry the command after fixing this.")
        return 1
    finally:
        lock.release()

    print("MiniMax audio is installed and configured. Existing engines and server settings are preserved.")
    print("The first music job downloads about 28.5 GB of model weights unless they are already cached.")
    print("When the agent is idle, apply the configuration: comfier-agent service restart")
    print("For a foreground agent, stop and rerun comfier-agent run instead.")
    return 0
