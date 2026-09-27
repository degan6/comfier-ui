import asyncio
import hashlib
import sys
import types

import pytest
from aiohttp import web

from comfier_agent.config import AgentConfig
from comfier_agent.models import ModelDownloadManager, _safe_filename


@pytest.fixture
def model_paths(tmp_path, monkeypatch):
    root = tmp_path / "models" / "checkpoints"
    root.mkdir(parents=True)
    fp = types.ModuleType("folder_paths")
    fp.folder_names_and_paths = {"checkpoints": ([str(root)], {".safetensors"})}
    fp.get_folder_paths = lambda name: fp.folder_names_and_paths[name][0]
    monkeypatch.setitem(sys.modules, "folder_paths", fp)
    return root


def test_unsafe_filenames():
    assert not _safe_filename("../x.safetensors")
    assert not _safe_filename("/abs.safetensors")
    assert not _safe_filename("C:\\x.safetensors")
    assert not _safe_filename(".hidden/x.safetensors")
    assert not _safe_filename("a/b/c/d/e.safetensors")


@pytest.mark.asyncio
async def test_model_download_happy_path(model_paths):
    sent = []

    async def send(msg):
        sent.append(msg)

    async def rescan():
        return None

    app = web.Application()
    payload = b"\x00" * 16 + b'{"format":"pt"}'  # not valid safetensors - use gguf ext instead
    payload = b"GGUF" + b"x" * 100

    async def file_handler(_request):
        return web.Response(body=payload)

    app.router.add_get("/model.gguf", file_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]  # noqa: SLF001
    url = f"http://127.0.0.1:{port}/model.gguf"

    import aiohttp

    session = aiohttp.ClientSession()
    cfg = AgentConfig(
        frontend_url="http://fe",
        api_key="k",
        allow_insecure=True,
        allow_model_downloads=True,
        allow_pickle_formats=True,
    )
    mgr = ModelDownloadManager(cfg, session, send, rescan)
    digest = hashlib.sha256(payload).hexdigest()
    await mgr.handle({
        "download_id": "d_1",
        "url": url,
        "folder": "checkpoints",
        "filename": "test/model.gguf",
        "sha256": digest,
        "bytes": len(payload),
    })
    await asyncio.sleep(0.5)
    assert (model_paths / "test" / "model.gguf").is_file()
    assert any(m.get("type") == "model.download.completed" for m in sent)
    await session.close()
    await runner.cleanup()


@pytest.mark.asyncio
async def test_model_download_disabled(model_paths):
    sent = []

    async def send(msg):
        sent.append(msg)

    import aiohttp

    session = aiohttp.ClientSession()
    cfg = AgentConfig(frontend_url="http://fe", api_key="k", allow_insecure=True, allow_model_downloads=False)
    mgr = ModelDownloadManager(cfg, session, send, lambda: None)
    await mgr.handle({
        "download_id": "d_2",
        "url": "http://x/f.safetensors",
        "folder": "checkpoints",
        "filename": "f.safetensors",
    })
    await asyncio.sleep(0.1)
    assert sent[-1]["reason"] == "disabled"
    await session.close()
