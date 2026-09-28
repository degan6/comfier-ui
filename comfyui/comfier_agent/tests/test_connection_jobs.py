import asyncio
import json
import sys
import types

import pytest
from fake_comfy import FakeComfy
from fake_frontend import FakeFrontend

from comfier_agent.config import AgentConfig
from comfier_agent.jobs import JobManager, delete_job_inputs, find_missing_models
from comfier_agent.runtime import AgentRuntime


@pytest.fixture
def folder_paths_stub(tmp_path, monkeypatch):
    models = tmp_path / "models"
    inp = tmp_path / "input"
    out = tmp_path / "output"
    for p in (models / "checkpoints", inp / "comfier", out):
        p.mkdir(parents=True)
    fp = types.ModuleType("folder_paths")
    fp.folder_names_and_paths = {"checkpoints": ([str(models / "checkpoints")], {".safetensors"})}
    fp.get_folder_paths = lambda name: fp.folder_names_and_paths[name][0]
    fp.get_input_directory = lambda: str(inp)
    fp.get_output_directory = lambda: str(out)
    fp.get_directory_by_type = lambda t: {"input": str(inp), "output": str(out), "temp": str(out)}.get(t)
    monkeypatch.setitem(sys.modules, "folder_paths", fp)
    return {"fp": fp, "inp": inp}


@pytest.mark.asyncio
async def test_hello_status_inventory_order(folder_paths_stub):
    comfy = FakeComfy()
    front = FakeFrontend()
    fe_base = await front.start()
    cu_base = await comfy.start()
    cfg = AgentConfig(
        frontend_url=fe_base,
        api_key="test-key",
        comfyui_url=cu_base,
        allow_insecure=True,
        enabled=True,
        min_free_disk_gb=0,
    )
    runtime = AgentRuntime(cfg)
    task = asyncio.create_task(runtime.run(sidecar=True))
    try:
        await front.wait_for_types("hello", "inventory", "status", "job.request", timeout=8)
        hello = [m for m in front.messages if m["type"] == "hello"][-1]
        assert hello["resources"]["machine_type"] == "cuda"
        assert hello["resources"]["comfyui_version"] == "0.3.test"
        hello_idx = next(i for i, m in enumerate(front.messages) if m["type"] == "hello")
        after = [m["type"] for m in front.messages[hello_idx:]]
        assert after.index("hello") < after.index("inventory") < after.index("status")
        assert front.auth_header_seen == "Bearer test-key"
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await front.stop()
        await comfy.stop()


@pytest.mark.asyncio
async def test_job_happy_path(folder_paths_stub):
    inp = folder_paths_stub["inp"]
    comfy = FakeComfy()
    front = FakeFrontend()
    fe_base = await front.start()
    cu_base = await comfy.start()
    cfg = AgentConfig(
        frontend_url=fe_base,
        api_key="test-key",
        comfyui_url=cu_base,
        allow_insecure=True,
        enabled=True,
        keep_outputs=True,
        comfyui_input_dir=str(inp),
        min_free_disk_gb=0,
    )
    runtime = AgentRuntime(cfg)
    run_task = asyncio.create_task(runtime.run(sidecar=True))
    await front.wait_for_types("job.request", timeout=8)
    req = [m for m in front.messages if m["type"] == "job.request"][-1]
    assign = {
        "type": "job.assign",
        "request_id": req["request_id"],
        "job_id": "j_1",
        "workflow": {
            "3": {"class_type": "LoadImage", "inputs": {"image": "comfier-input://in_0"}},
        },
        "inputs": [{
            "id": "in_0",
            "url": f"{fe_base}/api/agent/jobs/j_1/inputs/in_0",
            "filename": "photo.png",
            "bytes": len(front.input_payload),
        }],
        "upload_url": f"{fe_base}/api/agent/jobs/j_1/outputs",
        "requires": {"node_types": ["LoadImage"], "models": {}},
        "timeout_s": 30,
    }
    await front.ws.send_str(json.dumps(assign))
    await front.wait_for_types("job.accepted", timeout=8)
    await asyncio.sleep(0.3)
    assert comfy.last_prompt is not None
    assert comfy.last_prompt["extra_data"]["comfier_job_id"] == "j_1"
    prompt_id = "p_1"
    await comfy.push_ws({"type": "execution_start", "prompt_id": prompt_id})
    await comfy.push_ws({"type": "execution_cached", "prompt_id": prompt_id, "nodes": ["1", "2"]})
    await comfy.push_ws({"type": "executing", "prompt_id": prompt_id, "node": "3"})
    await comfy.push_ws({"type": "progress", "prompt_id": prompt_id, "value": 1, "max": 1})
    comfy.output_files["out.png"] = b"PNG"
    comfy.history[prompt_id] = {
        "outputs": {"9": {"images": [{"filename": "out.png", "type": "output", "subfolder": ""}]}},
    }
    await comfy.push_ws({"type": "execution_success", "prompt_id": prompt_id})
    await front.wait_for_types("job.completed", timeout=8)
    completed = [m for m in front.messages if m.get("type") == "job.completed"][-1]
    assert completed["outputs"][0]["kind"] == "image"
    assert front.uploads
    timings = completed["timings"]
    assert timings["nodes_cached"] == 2
    phase_sum = timings["inputs_ms"] + timings["local_queue_ms"] + timings["execute_ms"] + timings["upload_ms"]
    assert phase_sum <= completed["duration_ms"] + 50
    assert timings["input_bytes"] == len(front.input_payload)
    assert timings["output_bytes"] > 0
    assert "comfier-input://" not in json.dumps(comfy.last_prompt)
    run_task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await run_task
    await front.stop()
    await comfy.stop()


@pytest.mark.asyncio
async def test_job_gating_rejections(folder_paths_stub):
    sent = []

    async def send(msg):
        sent.append(msg)

    class Inv:
        node_types = ["LoadImage"]
        models = {"checkpoints": ["missing.safetensors"]}

    from comfier_agent.comfy_client import ComfyClient

    comfy = ComfyClient("http://127.0.0.1:9")
    cfg = AgentConfig(frontend_url="http://x", api_key="k", allow_insecure=True)
    mgr = JobManager(cfg, comfy, send, lambda: Inv())
    mgr.open_request_id = "r_1"
    await mgr.handle_assign(
        {"job_id": "j_x", "request_id": "r_9", "workflow": {}, "inputs": [], "upload_url": "http://x/o"},
        accepting=True,
        inventory=Inv(),
    )
    assert sent[-1]["reason"] == "busy"

    sent.clear()
    mgr.open_request_id = "r_1"
    await mgr.handle_assign(
        {
            "job_id": "j_x",
            "request_id": "r_1",
            "workflow": {},
            "inputs": [],
            "upload_url": "http://x/o",
            "requires": {"node_types": ["MissingNode"], "models": {}},
        },
        accepting=True,
        inventory=Inv(),
    )
    assert sent[-1]["reason"] == "missing_nodes"


def test_model_check_allows_folder_aliases_and_unknown_folders():
    installed = {
        "diffusion_models": ["wan.safetensors"],
        "clip": ["t5.safetensors"],
        "loras": ["sub/style.safetensors"],
    }
    required = {
        "unet": ["wan.safetensors"],
        "text_encoders": ["t5.safetensors"],
        "unknown": ["style.safetensors", "gone.safetensors"],
        "checkpoints": ["wan.safetensors"],
    }
    assert find_missing_models(required, installed) == ["unknown/gone.safetensors", "checkpoints/wan.safetensors"]


def test_cleanup_deletes_only_job_inputs(folder_paths_stub):
    inp = folder_paths_stub["inp"]
    cfg = AgentConfig(comfyui_input_dir=str(inp))
    comfier = inp / "comfier"
    mine = comfier / "j_1_in_0_photo.png"
    other = comfier / "j_2_in_0_photo.png"
    mine.write_bytes(b"x")
    other.write_bytes(b"x")
    delete_job_inputs(cfg, "j_1")
    assert not mine.exists()
    assert other.exists()
