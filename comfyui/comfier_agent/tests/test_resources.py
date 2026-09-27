import pytest

from comfier_agent.config import AgentConfig
from comfier_agent.jobs import JobManager
from comfier_agent.resources import build_resources, collapse_disk_free, disk_acceptance, machine_type_label
from comfier_agent.status import StatusTracker


def test_build_resources_from_comfy_stats():
    stats = {
        "system": {
            "os": "posix",
            "comfyui_version": "0.3.62",
            "ram_total": 64_000_000_000,
            "ram_free": 32_000_000_000,
        },
        "devices": [{
            "name": "cuda:0 NVIDIA RTX 4090",
            "type": "cuda",
            "vram_total": 25_000_000_000,
            "vram_free": 20_000_000_000,
        }],
    }
    resources = build_resources(stats, config=AgentConfig(backend_name="studio"))
    assert resources["machine_type"] == "cuda"
    assert resources["comfyui_version"] == "0.3.62"
    assert resources["ram"]["total_bytes"] == 64_000_000_000
    assert resources["gpus"][0]["vram_free_bytes"] == 20_000_000_000


def test_collapse_disk_free_when_single_volume():
    assert collapse_disk_free({"checkpoints": 100, "loras": 100}) == {"disk": 100}
    assert collapse_disk_free({"checkpoints": 100, "loras": 50})["loras"] == 50


def test_machine_type_apple_silicon():
    assert machine_type_label([{"type": "mps"}]) == "apple_silicon"


def test_disk_acceptance_blocks_when_low(tmp_path):
    cfg = AgentConfig(
        comfyui_output_dir=str(tmp_path),
        min_free_disk_gb=10,
    )
    ok, reason = disk_acceptance(cfg)
    assert ok
    assert reason is None

    cfg.min_free_disk_gb = 1_000_000
    ok, reason = disk_acceptance(cfg)
    assert not ok
    assert reason
    assert "GB free disk" in reason


@pytest.mark.asyncio
async def test_status_disk_low_state(tmp_path):
    from comfier_agent.comfy_client import ComfyClient

    class FakeComfy(ComfyClient):
        async def system_stats(self):
            return {"system": {"comfyui_version": "0.3.test"}, "devices": []}

        async def queue(self):
            return {"queue_running": [], "queue_pending": []}

    cfg = AgentConfig(comfyui_output_dir=str(tmp_path), min_free_disk_gb=1_000_000)
    tracker = StatusTracker(cfg, started_at=0)
    await tracker.refresh(
        FakeComfy("http://127.0.0.1:1"),
        comfier_prompt_ids=set(),
        active_job=None,
        downloads=[],
        comfy_reachable=True,
    )
    assert tracker.snapshot.state == "disk_low"
    assert not tracker.snapshot.accepting
    assert tracker.snapshot.accepting_reason
    msg = tracker.to_message()
    assert msg["resources"]["comfyui_version"] == "0.3.test"
    assert msg["accepting_reason"]


@pytest.mark.asyncio
async def test_job_rejected_disk_full_when_low_disk():
    sent = []

    async def send(msg):
        sent.append(msg)

    from comfier_agent.comfy_client import ComfyClient

    class Inv:
        node_types = []
        models = {}

    mgr = JobManager(AgentConfig(), ComfyClient("http://127.0.0.1:9"), send, lambda: Inv())
    mgr.open_request_id = "r_1"
    await mgr.handle_assign(
        {"job_id": "j_1", "request_id": "r_1", "workflow": {}, "inputs": [], "upload_url": "http://x/o"},
        accepting=False,
        inventory=Inv(),
        accepting_reason="Less than 10 GB free disk for jobs (1.0 GB on output)",
    )
    assert sent[-1]["reason"] == "disk_full"
    assert "disk" in sent[-1]["detail"].lower()
