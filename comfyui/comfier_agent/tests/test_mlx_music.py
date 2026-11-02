import asyncio
import json
import sys
import types
from pathlib import Path

import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.engines import build_engines, engine_names
from comfier_agent.engines.base import JobCancelled, JobContext, JobError
from comfier_agent.engines.mlx_music import MlxMusicEngine
from comfier_agent.music_models import MODELS, complete_snapshot
from comfier_agent.workers import music_worker

FAKE = str(Path(__file__).with_name("fake_music_worker.py"))
RECIPE = {"command": "mlx_music.generate", "model": "yue2", "prompt": "warm piano", "duration": 1, "seed": 0}


@pytest.fixture
def engine(tmp_path):
    return MlxMusicEngine(AgentConfig(work_dir=str(tmp_path)), [sys.executable, FAKE])


@pytest.mark.parametrize("overrides", [
    {"model": "unknown"}, {"model": []}, {"command": "os.system"}, {"output": "/tmp/song.wav"},
    {"duration": 0}, {"duration": True}, {"seed": -1}, {"lyrics": []}, {"prompt": "a"},
    {"model": "minimax-music3", "steps": 31}, {"model": "minimax-music3", "duration": 301},
    {"model": "minimax-music3", "planning": "full"}, {"planning": "other"},
])
def test_rejects_invalid_music_recipes(engine, overrides):
    with pytest.raises(JobError):
        engine.validate({**RECIPE, **overrides})


@pytest.mark.parametrize("model", MODELS)
def test_both_models_accept_instrumental_and_vocal_recipes(engine, model):
    engine.validate({**RECIPE, "model": model})
    engine.validate({**RECIPE, "model": model, "lyrics": "A song about the sea"})


@pytest.mark.asyncio
async def test_inventory_download_and_model_mapping(engine):
    await engine.refresh()
    assert engine.info()["models"] == ["yue2"]
    assert engine.info()["catalog"] == list(MODELS)
    assert await engine.repos_for("minimax-music3") == [MODELS["minimax-music3"]["repo"]]
    assert engine.download_argv("yue2")[-2:] == ["--download", "yue2"]
    with pytest.raises(ValueError):
        engine.download_argv("arbitrary/repo")
    progress = []

    async def report(value):
        progress.append(value)

    await engine.download("yue2", progress=report, cancelled=lambda: False)
    assert engine._refreshed_at is None


@pytest.mark.asyncio
@pytest.mark.parametrize("model", MODELS)
async def test_job_writes_audio_and_frees_process(engine, model):
    events = []

    async def progress(ctx, phase, fraction, **extra):
        events.append((phase, fraction))

    outputs = await engine.execute(JobContext("music1"), {**RECIPE, "model": model}, timeout_s=5, progress=progress)
    assert outputs[0]["filename"] == "music_music1.wav"
    assert Path(await engine.fetch_output(outputs[0])).stat().st_size > 44
    assert not engine.process.running
    assert ("loading_model", 0.0) in events


@pytest.mark.asyncio
@pytest.mark.parametrize("prompt, message", [("worker error", "inference failed"), ("no output", "stopped")])
async def test_failure_is_reported(engine, prompt, message):
    async def progress(*args, **kwargs):
        pass

    with pytest.raises(JobError, match=message):
        await engine.execute(JobContext("fail1"), {**RECIPE, "prompt": prompt}, timeout_s=5, progress=progress)
    assert not engine.process.running


@pytest.mark.asyncio
async def test_cancellation_kills_worker(engine):
    ctx = JobContext("cancel1")
    loaded = asyncio.Event()

    async def progress(ctx, phase, fraction, **extra):
        if phase == "running":
            loaded.set()

    task = asyncio.create_task(engine.execute(ctx, {**RECIPE, "prompt": "wait forever"},
                                              timeout_s=5, progress=progress))
    await asyncio.wait_for(loaded.wait(), 5)
    ctx.cancel_requested = True
    await engine.cancel(ctx)
    with pytest.raises(JobCancelled):
        await task
    assert not engine.process.running


@pytest.mark.asyncio
async def test_timeout_kills_worker(engine):
    async def progress(*args, **kwargs):
        pass

    with pytest.raises(JobError, match="timed out"):
        await engine.execute(JobContext("timeout1"), {**RECIPE, "prompt": "wait forever"}, timeout_s=0,
                             progress=progress)
    assert not engine.process.running


def test_incomplete_minimax_snapshot_is_not_reported(tmp_path):
    (tmp_path / "model.safetensors.index.json").write_text(json.dumps({"weight_map": {"x": "a.safetensors"}}))
    assert not complete_snapshot(tmp_path, "minimax-music3")
    for name in ["a.safetensors", "config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"]:
        path = tmp_path / name
        path.parent.mkdir(exist_ok=True)
        path.write_text("test")
    assert complete_snapshot(tmp_path, "minimax-music3")
    (tmp_path / "a.safetensors").write_bytes(b"")
    assert not complete_snapshot(tmp_path, "minimax-music3")


def test_download_pins_revision_and_inventory_stays_offline(monkeypatch, tmp_path):
    calls = []

    def download(**kwargs):
        calls.append(kwargs)
        return str(tmp_path)

    monkeypatch.setitem(sys.modules, "huggingface_hub", types.SimpleNamespace(snapshot_download=download))
    monkeypatch.setattr(music_worker, "complete_snapshot", lambda *_: True)
    music_worker.snapshot("yue2", local=True)
    assert calls[0]["local_files_only"] is True
    assert calls[0]["revision"] == MODELS["yue2"]["revision"]
    assert "generate.py" in calls[0]["allow_patterns"]


def test_blank_lyrics_condition_instrumentals(monkeypatch, tmp_path):
    seen = []
    monkeypatch.setattr(music_worker, "snapshot", lambda _: tmp_path)

    def generate(path, recipe, output):
        import wave
        seen.append(recipe)
        with wave.open(str(output), "wb") as audio:
            audio.setnchannels(2)
            audio.setsampwidth(2)
            audio.setframerate(44100)
            audio.writeframes(b"\0" * 100)

    monkeypatch.setattr(music_worker, "run_minimax", generate)
    music_worker.generate({**RECIPE, "model": "minimax-music3"}, tmp_path / "out.wav")
    assert seen[0]["lyrics"] == "[Instrumental]"
    assert seen[0]["prompt"].endswith("instrumental, no vocals")
    assert seen[0]["seed"] == 0


def test_engine_registration(monkeypatch):
    from comfier_agent import engines
    monkeypatch.setattr(engines, "installed", lambda name: name == "mlx_audio")
    assert "mlx_music" in engine_names(AgentConfig())
    assert isinstance(build_engines(AgentConfig(engines=["mlx_music"]), None)["mlx_music"], MlxMusicEngine)


@pytest.mark.asyncio
@pytest.mark.parametrize("model", MODELS)
async def test_music_only_agent_uploads_audio(agent, monkeypatch, comfier_home, model):
    from comfier_agent.engines import mlx_music
    monkeypatch.setattr(mlx_music, "default_worker_argv", lambda: [sys.executable, FAKE])
    await agent.comfy.stop()
    runtime = await agent.start(engines=["mlx_music"], work_dir=str(comfier_home / "work"))
    hello = agent.front.of_type("hello")[-1]
    assert set(hello["engines"]) == {"mlx_music"}
    assert hello["engines"]["mlx_music"]["models"] == ["yue2"]
    await agent.front.send(agent.assign("j_music", engine="mlx_music", inputs=[], requires={},
                                        workflow={**RECIPE, "model": model}))
    done = (await agent.front.wait_for_types("job.completed", timeout=10))[0]
    output = done["outputs"][0]
    assert output["kind"] == "audio"
    assert output["mime"] in {"audio/wav", "audio/x-wav"}
    assert output["filename"] == "music_j_music.wav"
    assert agent.front.uploads[-1]["filename"] == "music_j_music.wav"
    assert not runtime.engines["mlx_music"].process.running
    assert not (Path(runtime.config.work_dir) / "j_music").exists()
