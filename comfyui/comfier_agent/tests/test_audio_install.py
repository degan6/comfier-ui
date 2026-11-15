"""Audio onboarding must preserve existing agent settings and fail before enabling broken runtimes."""

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from comfier_agent import audio_install, cli


@pytest.fixture
def installer(monkeypatch):
    monkeypatch.setattr(audio_install.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(audio_install.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(audio_install.shutil, "which", lambda name: "/opt/homebrew/bin/uv")
    calls = []

    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        return SimpleNamespace(stdout='{"version": "test"}\n')

    monkeypatch.setattr(audio_install.subprocess, "run", run)
    return calls


def test_install_preserves_settings_and_reuses_runtime(comfier_home, installer, capsys):
    comfier_home.mkdir()
    path = comfier_home / "agent.json"
    settings = {"api_key": "cmf_secret", "engines": ["mflux", "mlx_video"], "custom": "keep"}
    path.write_text(json.dumps(settings))
    assert cli.main(["install", "audio"]) == 0
    saved = json.loads(path.read_text())
    assert saved == {**settings, "engines": ["mflux", "mlx_video", "mlx_audio"],
                     "mlx_audio_python": str(comfier_home / "audio/bin/python")}
    assert path.stat().st_mode & 0o777 == 0o600
    assert installer[-1][1]["env"]["PYTHONPATH"]
    assert "cmf_secret" not in capsys.readouterr().out
    python = comfier_home / "audio/bin/python"
    python.parent.mkdir(parents=True)
    python.touch()
    installer.clear()
    assert cli.main(["install", "audio"]) == 0
    assert not any("venv" in argv for argv, _ in installer)
    assert json.loads(path.read_text()) == saved


@pytest.mark.parametrize("failure", ["pip", "probe", "invalid_probe"])
def test_failed_install_does_not_change_config(comfier_home, installer, monkeypatch, failure):
    comfier_home.mkdir()
    path = comfier_home / "agent.json"
    original = '{"api_key":"cmf_secret","engines":["mflux"]}'
    path.write_text(original)

    def run(argv, **kwargs):
        if failure == "pip" and "pip" in argv:
            raise subprocess.CalledProcessError(1, argv)
        if "--probe" in argv:
            return SimpleNamespace(stdout='{"error":"broken native library"}' if failure == "probe" else '')
        return SimpleNamespace(stdout='')

    monkeypatch.setattr(audio_install.subprocess, "run", run)
    assert cli.main(["install", "audio"]) == 1
    assert path.read_text() == original


def test_auto_detection_stays_enabled(comfier_home, installer):
    assert cli.main(["install", "audio"]) == 0
    assert "engines" not in json.loads((comfier_home / "agent.json").read_text())


@pytest.mark.parametrize("contents", ['{broken', '[]', '{"engines":"mflux"}'])
def test_invalid_settings_are_preserved(comfier_home, installer, contents):
    comfier_home.mkdir()
    path = comfier_home / "agent.json"
    path.write_text(contents)
    assert cli.main(["install", "audio"]) == 1
    assert path.read_text() == contents
    assert installer == []


def test_requires_apple_silicon(installer, monkeypatch):
    monkeypatch.setattr(audio_install.platform, "machine", lambda: "x86_64")
    assert cli.main(["install", "audio"]) == 1
    assert installer == []


def test_requires_uv(installer, monkeypatch):
    monkeypatch.setattr(audio_install.shutil, "which", lambda name: None)
    assert cli.main(["install", "audio"]) == 1
    assert installer == []


def test_installer_pins_match_audio_extra():
    project = (Path(__file__).parents[1] / "pyproject.toml").read_text()
    extras = project.split("audio = [", 1)[1].split("]", 1)[0]
    assert all(requirement in extras for requirement in audio_install.AUDIO_REQUIREMENTS)


def test_runtime_changes_hold_the_shared_gpu_lock(comfier_home, installer, monkeypatch):
    from comfier_agent.gpu_lock import GpuLock

    def run(argv, **kwargs):
        assert GpuLock(str(comfier_home / "gpu.lock")).held_elsewhere()
        return SimpleNamespace(stdout='{"version":"test"}\n')

    monkeypatch.setattr(audio_install.subprocess, "run", run)
    assert cli.main(["install", "audio"]) == 0
    assert not GpuLock(str(comfier_home / "gpu.lock")).held_elsewhere()
