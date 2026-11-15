"""MiniMax recipes use an isolated process and the existing shared job lifecycle."""
import asyncio
import json
import sys
import types
import wave
from pathlib import Path

import numpy as np
import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.engines.base import JobCancelled, JobContext, JobError
from comfier_agent.engines.mlx_audio import MlxAudioEngine, worker_argv
from comfier_agent.workers import minimax_music as worker

FAKE = str(Path(__file__).with_name('fake_mlx_audio.py'))
RECIPE = {'command': 'minimax-music3', 'model': worker.MODEL, 'caption': 'a duet',
          'lyrics': '[Verse]\nExact words\n[Chorus]\nA melody', 'duration': 60, 'steps': 20,
          'seed': 2211510127, 'min_memory_gb': 96}


def make_engine(tmp_path, **config):
    return MlxAudioEngine(AgentConfig(work_dir=str(tmp_path), **config), runner_argv=[sys.executable, FAKE])


async def quiet(*_args, **_kwargs):
    pass


@pytest.mark.parametrize('patch', [
    {'steps': 31}, {'steps': 1.5}, {'seed': -1}, {'seed': True}, {'duration': 301}, {'duration': float('nan')},
    {'model': 'other/model'}, {'lyrics': ''}, {'caption': ''}, {'output': '/tmp/a.wav'}, {'planning': 'full'},
])
def test_bad_recipe_fails_before_launch(tmp_path, patch):
    with pytest.raises(JobError):
        make_engine(tmp_path).validate({**RECIPE, **patch})


@pytest.mark.asyncio
async def test_native_request_preserves_lyrics_seed_and_audio_rate(tmp_path):
    engine = make_engine(tmp_path)
    phases = []

    async def progress(_ctx, phase, fraction):
        phases.append((phase, fraction))

    files = await engine.execute(JobContext(job_id='j_1', engine='mlx_audio'), RECIPE, timeout_s=10, progress=progress)
    assert len(files) == 1 and files[0]['filename'] == 'mlx_audio_j_1.wav'
    path = Path(files[0]['path'])
    assert json.loads(path.with_suffix('.request.json').read_text()) == RECIPE
    with wave.open(str(path)) as audio:
        assert audio.getframerate() == 44100 and audio.getnchannels() == 2
    assert ('loading_model', 0.0) in phases and ('running', 0.0) in phases
    assert all(fraction == 0 for _, fraction in phases)  # no invented percentage
    assert not engine.process.running


@pytest.mark.asyncio
async def test_cancel_and_timeout_stop_the_child(tmp_path):
    engine = make_engine(tmp_path)
    ctx = JobContext(job_id='j_cancel', engine='mlx_audio')
    running = asyncio.Event()

    async def progress(_ctx, phase, _fraction):
        if phase == 'running':
            running.set()

    task = asyncio.create_task(engine.execute(ctx, {**RECIPE, 'caption': 'hang'}, timeout_s=30, progress=progress))
    await asyncio.wait_for(running.wait(), 5)
    ctx.cancel_requested = True
    await engine.cancel(ctx)
    with pytest.raises(JobCancelled):
        await task
    assert not engine.process.running
    with pytest.raises(JobError, match='timeout'):
        await engine.execute(JobContext(job_id='j_timeout'), {**RECIPE, 'caption': 'hang'},
                             timeout_s=.1, progress=quiet)
    assert not engine.process.running


@pytest.mark.asyncio
async def test_child_failure_has_native_error(tmp_path):
    engine = make_engine(tmp_path)
    with pytest.raises(JobError, match='bad native waveform'):
        await engine.execute(JobContext(job_id='j_fail'), {**RECIPE, 'caption': 'fail'},
                             timeout_s=5, progress=quiet)


@pytest.mark.asyncio
async def test_probe_and_download_use_the_same_worker(tmp_path):
    engine = make_engine(tmp_path)
    await engine.refresh()
    assert engine.version == '0.4.0' and engine.models == [worker.MODEL]
    assert engine.download_argv(worker.MODEL) == [sys.executable, FAKE, '--download', worker.MODEL]
    assert await engine.repos_for(worker.MODEL) == [worker.MODEL]
    with pytest.raises(ValueError):
        engine.download_argv('unrelated/model')


def test_external_interpreter_is_used_for_every_operation(tmp_path, monkeypatch):
    from comfier_agent import engines

    python = tmp_path / 'python'
    python.touch()
    config = AgentConfig(mlx_audio_python=str(python))
    monkeypatch.setattr(engines, 'installed', lambda _package: False)
    assert engines.engine_names(config) == ['comfyui', 'mlx_audio']
    assert worker_argv(config)[0] == str(python)
    assert isinstance(engines.build_engines(config, None)['mlx_audio'], MlxAudioEngine)


def test_complete_snapshot_checks_every_weight_and_real_tokenizer(tmp_path):
    (tmp_path / 'model.safetensors.index.json').write_text(json.dumps({'weight_map': {'a': 'shard.safetensors'}}))
    (tmp_path / 'config.json').write_text('{}')
    (tmp_path / 'shard.safetensors').write_bytes(b'weights')
    assert not worker.complete_snapshot(tmp_path)
    (tmp_path / 'tokenizer').mkdir()
    (tmp_path / 'tokenizer/tokenizer.json').write_text('{}')
    assert worker.complete_snapshot(tmp_path)
    (tmp_path / 'shard.safetensors').unlink()
    assert not worker.complete_snapshot(tmp_path)


def stub_runtime(monkeypatch, tmp_path, audio, rate=44100, controls=None):
    mx = types.ModuleType('mlx.core')
    mx.get_peak_memory = lambda: 123
    package = types.ModuleType('mlx')
    package.core = mx
    monkeypatch.setitem(sys.modules, 'mlx', package)
    monkeypatch.setitem(sys.modules, 'mlx.core', mx)
    music = types.ModuleType('mlx_audio.music')
    calls = []
    ar = types.ModuleType('mlx_audio.music.models.minimax_music3.ar')
    ar.AR_CFG_SCALE, ar.AR_CFG_TOP_K, ar.AR_SAMPLING_TOP_K = 1.5, 50, 50
    pipeline = types.ModuleType('mlx_audio.music.models.minimax_music3.minimax_music3')
    pipeline.DIT_CFG_SCALE = 1.7
    monkeypatch.setitem(sys.modules, ar.__name__, ar)
    monkeypatch.setitem(sys.modules, pipeline.__name__, pipeline)
    expected = {'semantic_guidance': 1.5, 'acoustic_guidance': 1.7, 'top_k': 50, **(controls or {})}

    class Model:
        def generate(self, **kwargs):
            # These are the module globals read by the pinned runtime's AR and flow stages.
            assert ar.AR_CFG_SCALE == expected['semantic_guidance']
            assert ar.AR_CFG_TOP_K == ar.AR_SAMPLING_TOP_K == expected['top_k']
            assert pipeline.DIT_CFG_SCALE == expected['acoustic_guidance']
            calls.append(kwargs)
            yield types.SimpleNamespace(audio=audio, sample_rate=rate)

    music.load = lambda _path: Model()
    io = types.ModuleType('mlx_audio.audio_io')
    writes = []

    def write(path, data, sample_rate):
        writes.append(sample_rate)
        Path(path).write_bytes(b'wave')

    io.write = write
    monkeypatch.setitem(sys.modules, 'mlx_audio', types.ModuleType('mlx_audio'))
    monkeypatch.setitem(sys.modules, 'mlx_audio.music', music)
    monkeypatch.setitem(sys.modules, 'mlx_audio.audio_io', io)
    monkeypatch.setattr(worker, 'model_path', lambda **_: tmp_path)
    monkeypatch.setattr(worker.importlib.metadata, 'version', lambda _: 'tested')
    monkeypatch.setattr(worker.shutil, 'which', lambda _: None)
    return calls, writes


def test_worker_preserves_generation_options_and_result_sample_rate(tmp_path, monkeypatch):
    calls, writes = stub_runtime(monkeypatch, tmp_path, np.zeros((320, 2)), rate=32000)
    worker.generate(RECIPE, tmp_path / 'out.wav')
    assert calls == [{'text': RECIPE['caption'], 'lyrics': RECIPE['lyrics'], 'duration': 60,
                      'steps': 20, 'seed': 2211510127}]
    assert writes == [32000]
    metrics = json.loads((tmp_path / 'out.metrics.json').read_text())
    assert metrics['duration_seconds'] == .01 and metrics['revision'] == worker.REVISION


@pytest.mark.parametrize('audio', [np.zeros((0, 2)), np.full((20, 2), np.nan), np.zeros(20)])
def test_invalid_waveform_is_rejected_before_writing(tmp_path, monkeypatch, audio):
    _, writes = stub_runtime(monkeypatch, tmp_path, audio)
    with pytest.raises(ValueError, match='invalid or empty'):
        worker.generate(RECIPE, tmp_path / 'out.wav')
    assert writes == []


@pytest.mark.asyncio
async def test_audio_runs_without_comfyui_and_uploads_only_media(agent, tmp_path, monkeypatch):
    from comfier_agent.engines import mlx_audio

    monkeypatch.setattr(mlx_audio, 'worker_argv', lambda _config: [sys.executable, FAKE])
    await agent.comfy.stop()
    runtime = await agent.start(engines=['mlx_audio'], work_dir=str(tmp_path))
    await agent.front.send(agent.assign('j_audio', engine='mlx_audio', inputs=[], requires={}, workflow=RECIPE))
    completed = (await agent.front.wait_for_types('job.completed', timeout=10))[0]
    assert completed['outputs'][0]['kind'] == 'audio'
    assert len(completed['outputs']) == 1
    assert agent.front.of_type('hello')[-1]['engines']['mlx_audio']['version'] == '0.4.0'
    await runtime.engines['mlx_audio'].close()


def test_external_audio_interpreter_env_overrides_config(tmp_path, monkeypatch):
    from comfier_agent.config import load_config

    config = tmp_path / 'agent.json'
    config.write_text(json.dumps({'mlx_audio_python': '/file/python'}))
    monkeypatch.setenv('COMFIER_MLX_AUDIO_PYTHON', '/env/python')
    assert load_config(overrides={'config_path': config}).mlx_audio_python == '/env/python'


@pytest.mark.parametrize('fails', [False, True])
def test_optional_mp3_export_never_loses_wav(tmp_path, monkeypatch, fails):
    import subprocess

    stub_runtime(monkeypatch, tmp_path, np.zeros((100, 2)))
    monkeypatch.setattr(worker.shutil, 'which', lambda _: '/bin/ffmpeg')

    def encode(argv, **kwargs):
        Path(argv[-1]).write_bytes(b'mp3')
        if fails:
            raise subprocess.CalledProcessError(1, argv)

    monkeypatch.setattr(worker.subprocess, 'run', encode)
    worker.generate(RECIPE, tmp_path / 'out.wav')
    assert (tmp_path / 'out.wav').read_bytes() == b'wave'
    assert (tmp_path / 'out.mp3').exists() is not fails


def test_probe_rejects_an_older_mlx_audio_without_minimax(monkeypatch):
    monkeypatch.setattr(worker.importlib.metadata, 'version', lambda _: 'old-version')
    monkeypatch.setitem(sys.modules, 'mlx_audio', types.ModuleType('mlx_audio'))
    result = worker.probe()
    assert not result.get('version') and result['models'] == []
    assert 'runtime unavailable' in result['error']


@pytest.mark.asyncio
async def test_runtime_drops_broken_audio_then_recovers(tmp_path):
    from comfier_agent.runtime import AgentRuntime

    engine = make_engine(tmp_path)
    runtime = AgentRuntime(AgentConfig(engines=['mlx_audio']))
    runtime.engines = {'mlx_audio': engine}
    await engine.refresh()
    assert runtime.engine_available('mlx_audio')
    engine.runner_argv = [sys.executable, '-c', 'raise SystemExit(1)']
    engine._refreshed_at = None
    await engine.refresh()
    assert not runtime.engine_available('mlx_audio')
    assert engine.version is None and engine.models == []
    engine.runner_argv = [sys.executable, FAKE]
    await engine.refresh()
    assert runtime.engine_available('mlx_audio')


def test_complete_pinned_snapshot_is_reused_without_online_hub_calls(tmp_path, monkeypatch):
    hub = types.ModuleType('huggingface_hub')
    calls = []

    def snapshot_download(**options):
        calls.append(options)
        assert options['local_files_only'] is True
        return str(tmp_path)

    hub.snapshot_download = snapshot_download
    monkeypatch.setitem(sys.modules, 'huggingface_hub', hub)
    monkeypatch.setattr(worker, 'complete_snapshot', lambda _path: True)
    monkeypatch.setenv('HF_HUB_OFFLINE', '1')
    assert worker.model_path() == tmp_path
    assert calls[0]['revision'] == worker.REVISION


def test_incomplete_offline_snapshot_does_not_attempt_network(tmp_path, monkeypatch):
    hub = types.ModuleType('huggingface_hub')
    hub.snapshot_download = lambda **_: str(tmp_path)
    monkeypatch.setitem(sys.modules, 'huggingface_hub', hub)
    monkeypatch.setenv('HF_HUB_OFFLINE', '1')
    with pytest.raises(ValueError, match='incomplete'):
        worker.model_path()


@pytest.mark.parametrize('patch', [
    {'semantic_guidance': -0.1}, {'semantic_guidance': 10.1}, {'semantic_guidance': True},
    {'semantic_guidance': float('nan')}, {'acoustic_guidance': float('inf')},
    {'acoustic_guidance': '1.7'}, {'acoustic_guidance': False}, {'acoustic_guidance': -1},
    {'top_k': 0}, {'top_k': 16385}, {'top_k': 50.0}, {'top_k': True},
])
def test_invalid_literal_controls_fail_before_launch(tmp_path, patch):
    with pytest.raises(JobError):
        make_engine(tmp_path).validate({**RECIPE, **patch})


@pytest.mark.parametrize('controls', [
    {}, {'semantic_guidance': 0, 'acoustic_guidance': 10, 'top_k': 1},
    {'semantic_guidance': 10, 'acoustic_guidance': 0, 'top_k': 16384},
    {'semantic_guidance': 2.3, 'acoustic_guidance': 1.2, 'top_k': 73},
])
def test_recipe_controls_reach_both_stages_and_are_saved(tmp_path, monkeypatch, controls):
    calls, _writes = stub_runtime(monkeypatch, tmp_path, np.zeros((100, 2)), controls=controls)
    worker.generate({**RECIPE, **controls}, tmp_path / 'controlled.wav')
    # generate accepts **kwargs but ignores unknown ones: control values must not be passed that way.
    assert set(calls[0]) == {'text', 'lyrics', 'duration', 'steps', 'seed'}
    metrics = json.loads((tmp_path / 'controlled.metrics.json').read_text())
    expected = {'semantic_guidance': 1.5, 'acoustic_guidance': 1.7, 'top_k': 50, **controls}
    assert {key: metrics[key] for key in expected} == expected
    ar = sys.modules['mlx_audio.music.models.minimax_music3.ar']
    pipeline = sys.modules['mlx_audio.music.models.minimax_music3.minimax_music3']
    assert (ar.AR_CFG_SCALE, ar.AR_CFG_TOP_K, ar.AR_SAMPLING_TOP_K, pipeline.DIT_CFG_SCALE) == (1.5, 50, 50, 1.7)


def test_controls_restore_runtime_globals_after_generation_failure(tmp_path, monkeypatch):
    controls = {'semantic_guidance': 2.3, 'acoustic_guidance': 1.2, 'top_k': 73}
    stub_runtime(monkeypatch, tmp_path, np.full((10, 2), np.nan), controls=controls)
    ar = sys.modules['mlx_audio.music.models.minimax_music3.ar']
    pipeline = sys.modules['mlx_audio.music.models.minimax_music3.minimax_music3']
    ar.AR_CFG_SCALE, ar.AR_CFG_TOP_K, ar.AR_SAMPLING_TOP_K, pipeline.DIT_CFG_SCALE = 3, 80, 90, 4
    class FailedModel:
        def generate(self, **_kwargs):
            assert ar.AR_CFG_SCALE == controls['semantic_guidance']
            assert pipeline.DIT_CFG_SCALE == controls['acoustic_guidance']
            raise ValueError('synthesis failed')

    monkeypatch.setattr(sys.modules['mlx_audio.music'], 'load', lambda _path: FailedModel())
    with pytest.raises(ValueError, match='synthesis failed'):
        worker.generate({**RECIPE, **controls}, tmp_path / 'invalid.wav')
    assert (ar.AR_CFG_SCALE, ar.AR_CFG_TOP_K, ar.AR_SAMPLING_TOP_K, pipeline.DIT_CFG_SCALE) == (3, 80, 90, 4)
