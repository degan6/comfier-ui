"""YuE2's native API, cached weights and independent audio runtime routing."""
import json
import subprocess
import sys
import types
from pathlib import Path

import numpy as np
import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.engines.base import JobError
from comfier_agent.engines.mlx_audio import MlxAudioEngine
from comfier_agent.workers import audio_worker, yue2

RECIPE = {"command": "yue2", "model": yue2.MODEL, "style": "piano pop", "lyrics": "[Verse]\nExact words",
          "duration": 180, "steps": 32, "seed": 2211510127, "precision": "8bit", "cot": "full"}


@pytest.mark.parametrize("patch", [
    {"steps": True}, {"steps": 0}, {"steps": 65}, {"steps": 1.5}, {"seed": -1}, {"seed": 2**32},
    {"duration": 0}, {"duration": 361}, {"duration": float("nan")}, {"duration": float("inf")},
    {"precision": "4bit"}, {"cot": "wrong"}, {"abc": ""}, {"abc": "X:1", "cot": "off"},
    {"cfg_scale": True}, {"cfg_scale": float("nan")}, {"cfg_scale": 21}, {"style": ""},
    {"lyrics": ""}, {"model": "other/model"}, {"output": "/tmp/audio.wav"}, {"top_k": 50},
])
def test_invalid_recipe_rejected_before_launch(patch):
    engine = MlxAudioEngine(AgentConfig())
    with pytest.raises(JobError):
        engine.validate({**RECIPE, **patch})


def test_recipe_and_download_routed_to_yue2():
    engine = MlxAudioEngine(AgentConfig())
    engine.validate(RECIPE)
    assert engine.download_argv(yue2.MODEL)[-2:] == ["--download", yue2.MODEL]


def make_snapshot(path):
    for name in yue2.FILES:
        dest = path / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"weights")
    (path / "conversion.json").write_text(json.dumps({"files": {"ar-bf16.safetensors": {"bytes": 7}}}))
    (path / "vae/weights_manifest.json").write_text(json.dumps({"files": {"model.safetensors": {"bytes": 7}}}))


def test_snapshot_needs_both_ar_precisions_nar_tokenizer_and_complete_vae(tmp_path):
    make_snapshot(tmp_path)
    assert yue2.complete_snapshot(tmp_path)
    (tmp_path / "vae/model.safetensors").write_bytes(b"partial")
    assert yue2.complete_snapshot(tmp_path)  # correct length
    (tmp_path / "vae/model.safetensors").write_bytes(b"short")
    assert not yue2.complete_snapshot(tmp_path)
    make_snapshot(tmp_path)
    (tmp_path / "ar-bf16.safetensors").unlink()
    assert not yue2.complete_snapshot(tmp_path)


def test_hub_symlinks_materialized_without_polluting_generator(tmp_path):
    snapshot, target = tmp_path / "snapshot", tmp_path / "work"
    make_snapshot(snapshot)
    blob = tmp_path / "blob"
    (snapshot / "ar-8bit.safetensors").rename(blob)
    (snapshot / "ar-8bit.safetensors").symlink_to(blob)
    yue2.materialize(snapshot, target)
    assert not (target / "generator/ar-8bit.safetensors").is_symlink()
    assert (target / "generator/ar-8bit.safetensors").read_bytes() == b"weights"
    assert not (target / "generator/vae").exists()
    assert (target / "vae/model.safetensors").is_file()


@pytest.mark.parametrize("complete", [True, False])
def test_offline_snapshot_never_uses_network(tmp_path, monkeypatch, complete):
    if complete:
        make_snapshot(tmp_path)
    calls = []

    def download(**options):
        calls.append(options)
        assert options["local_files_only"] is True
        assert options["revision"] == yue2.REVISION
        return str(tmp_path)

    monkeypatch.setitem(sys.modules, "huggingface_hub", types.SimpleNamespace(snapshot_download=download))
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    if complete:
        assert yue2.model_path() == tmp_path
    else:
        with pytest.raises(ValueError, match="incomplete"):
            yue2.model_path()
    assert len(calls) == 1


def stub_pipeline(tmp_path, monkeypatch, audio, rate=48000):
    calls, writes = [], []

    class Pipeline:
        @classmethod
        def from_pretrained(cls, model, **kwargs):
            assert Path(model).name == "generator"
            assert Path(kwargs["vae"]).name == "vae"
            calls.append(kwargs)
            return cls()

        def __enter__(self):
            return self

        def __exit__(self, *_):
            calls.append("closed")

        def _load_model(self):
            calls.append("loaded")

        def __call__(self, **kwargs):
            assert calls[-1] == "loaded"
            calls.append(kwargs)
            return types.SimpleNamespace(audio=audio, sample_rate=rate)

    monkeypatch.setitem(sys.modules, "lyra", types.SimpleNamespace(
        YuE2Pipeline=Pipeline, Sampling=lambda **kw: kw, GenerationConfig=lambda **kw: kw))
    monkeypatch.setitem(sys.modules, "soundfile", types.SimpleNamespace(write=lambda *a, **kw: writes.append((a, kw))))
    monkeypatch.setattr(yue2, "model_path", lambda: tmp_path)
    monkeypatch.setattr(yue2, "materialize", lambda *_: None)
    monkeypatch.setattr(yue2.importlib.metadata, "version", lambda _: "tested")
    return calls, writes


def test_generation_uses_real_pipeline_controls_and_preserves_48khz_stereo(tmp_path, monkeypatch, capsys):
    calls, writes = stub_pipeline(tmp_path, monkeypatch, np.zeros((480, 2)))
    yue2.generate({**RECIPE, "abc": "X:1\nK:C\nC4|", "cfg_scale": 1.2}, tmp_path / "song.wav")
    assert calls[0]["generation_config"] == {"ode_steps": 32, "semantic": {"max_tokens": 4500, "min_tokens": 200}}
    assert calls[0]["local_files_only"] is True and calls[0]["precision"] == "8bit"
    assert calls[2] == {"style": RECIPE["style"], "lyrics": RECIPE["lyrics"], "seed": RECIPE["seed"],
                        "cot": "full", "abc": "X:1\nK:C\nC4|", "cfg_scale": 1.2}
    assert calls[-1] == "closed"
    assert writes[0][0][2] == 48000 and writes[0][1] == {"subtype": "PCM_24"}
    assert not list(tmp_path.glob("yue2-*"))
    metrics = json.loads(capsys.readouterr().out.splitlines()[-1])
    assert metrics["revision"] == yue2.REVISION and metrics["duration_seconds"] == .01


@pytest.mark.parametrize("audio,rate", [(np.zeros((0, 2)), 48000), (np.zeros(480), 48000),
                                        (np.full((480, 2), np.nan), 48000), (np.zeros((480, 2)), 44100)])
def test_bad_output_rejected_and_pipeline_closed(tmp_path, monkeypatch, audio, rate):
    calls, writes = stub_pipeline(tmp_path, monkeypatch, audio, rate)
    with pytest.raises(ValueError, match="invalid or empty"):
        yue2.generate(RECIPE, tmp_path / "song.wav")
    assert calls[-1] == "closed" and not writes


def test_inventory_keeps_working_yue2_when_minimax_runtime_fails(monkeypatch):
    def run(argv, **_):
        if "minimax_music" in argv[2]:
            raise subprocess.CalledProcessError(1, argv)
        return types.SimpleNamespace(stdout=json.dumps({"version": "0.1.0", "models": [yue2.MODEL]}))

    monkeypatch.setattr(audio_worker.subprocess, "run", run)
    result = audio_worker.probe()
    assert result["version"] and result["models"] == [yue2.MODEL]
    assert result["runtimes"]["minimax-music3"]["error"]
    assert not result["error"]


def test_isolated_python_is_used_for_yue2_only(monkeypatch):
    monkeypatch.setenv("COMFIER_YUE2_PYTHON", "/isolated/bin/python")
    assert audio_worker.worker_argv(yue2)[0] == "/isolated/bin/python"
    assert audio_worker.worker_argv(audio_worker.minimax_music)[0] == sys.executable


def test_agent_detects_isolated_yue2_without_other_mlx_packages(monkeypatch):
    from comfier_agent import engines
    monkeypatch.setattr(engines, "installed", lambda _: False)
    monkeypatch.setattr(audio_worker, "yue2_installed", lambda: True)
    assert engines.engine_names(AgentConfig()) == ["comfyui", "mlx_audio"]


@pytest.mark.asyncio
async def test_yue2_job_uploads_audio_without_comfyui(agent, tmp_path, monkeypatch):
    from comfier_agent.engines import mlx_audio

    fake = str(Path(__file__).with_name("fake_mlx_audio.py"))
    monkeypatch.setattr(mlx_audio, "default_worker_argv", lambda: [sys.executable, fake])
    await agent.comfy.stop()
    runtime = await agent.start(engines=["mlx_audio"], work_dir=str(tmp_path))
    await agent.front.send(agent.assign("j_yue2", engine="mlx_audio", inputs=[], requires={}, workflow=RECIPE))
    completed = (await agent.front.wait_for_types("job.completed", timeout=10))[0]
    assert len(completed["outputs"]) == 1
    assert completed["outputs"][0]["kind"] == "audio"
    await runtime.engines["mlx_audio"].close()
