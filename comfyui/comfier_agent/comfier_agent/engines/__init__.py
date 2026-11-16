"""Execution engines: ComfyUI, and the native Apple Silicon tools mflux, mlx-video and mlx-audio."""

from __future__ import annotations

import importlib.util
import logging

LOG = logging.getLogger("comfier_agent")

KNOWN = ("comfyui", "mflux", "mlx_video", "mlx_audio")
# The Python package each MLX engine needs.
MLX_PACKAGES = {"mflux": "mflux", "mlx_video": "mlx_video", "mlx_audio": "mlx_audio"}


def installed(package: str) -> bool:
    try:
        return importlib.util.find_spec(package) is not None
    except (ImportError, ValueError):
        return False


def runtime_installed(name: str, package: str) -> bool:
    from comfier_agent.workers.audio_worker import yue2_installed

    return installed(package) or (name == "mlx_audio" and (installed("lyra") or yue2_installed()))


def engine_names(config) -> list[str]:
    """The configured engines, or ComfyUI plus whichever MLX tools are installed."""
    if config.engines:
        unknown = [n for n in config.engines if n not in KNOWN]
        if unknown:
            LOG.warning("ignoring unknown engines: %s", ", ".join(unknown))
        return [n for n in KNOWN if n in config.engines]
    return ["comfyui", *(name for name, pkg in MLX_PACKAGES.items() if runtime_installed(name, pkg))]


def build_engines(config, comfy) -> dict:
    from comfier_agent.engines.comfyui import ComfyUIEngine

    engines = {}
    for name in engine_names(config):
        if name == "comfyui":
            engines[name] = ComfyUIEngine(comfy)
        elif name == "mflux":
            from comfier_agent.engines.mflux import MfluxEngine

            engines[name] = MfluxEngine(config)
        elif name == "mlx_video":
            from comfier_agent.engines.mlx_video import MlxVideoEngine

            engines[name] = MlxVideoEngine(config)
        elif name == "mlx_audio":
            from comfier_agent.engines.mlx_audio import MlxAudioEngine

            engines[name] = MlxAudioEngine(config)
        if name in MLX_PACKAGES and not runtime_installed(name, MLX_PACKAGES[name]):
            LOG.warning("%s is enabled but the %s package isn't installed; its jobs will fail", name,
                        MLX_PACKAGES[name])
    return engines
