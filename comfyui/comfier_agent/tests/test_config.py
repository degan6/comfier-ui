import json
import os

from comfier_agent.config import load_config, save_config


def test_env_overrides_file(monkeypatch, tmp_path):
    cfg_file = tmp_path / "comfier_agent.json"
    cfg_file.write_text(json.dumps({"frontend_url": "https://file.example", "api_key": "file-key"}), encoding="utf-8")
    monkeypatch.setenv("COMFIER_URL", "https://env.example")
    monkeypatch.setenv("COMFIER_API_KEY", "env-key")
    cfg = load_config(overrides={"config_path": cfg_file})
    assert cfg.frontend_url == "https://env.example"
    assert cfg.api_key == "env-key"


def test_missing_url_or_key_idle(monkeypatch):
    monkeypatch.delenv("COMFIER_URL", raising=False)
    monkeypatch.delenv("COMFIER_API_KEY", raising=False)
    cfg = load_config(overrides={"frontend_url": "", "api_key": ""})
    assert not cfg.ok


def test_http_rejected_without_insecure(monkeypatch):
    monkeypatch.setenv("COMFIER_URL", "http://localhost")
    monkeypatch.setenv("COMFIER_API_KEY", "k")
    cfg = load_config()
    assert not cfg.ok


def test_http_allowed_with_insecure(monkeypatch):
    monkeypatch.setenv("COMFIER_URL", "http://localhost")
    monkeypatch.setenv("COMFIER_API_KEY", "k")
    monkeypatch.setenv("COMFIER_ALLOW_INSECURE", "true")
    cfg = load_config()
    assert cfg.ok


def test_save_config_permissions(tmp_path):
    path = tmp_path / "comfier_agent.json"
    cfg = load_config(overrides={"frontend_url": "https://x", "api_key": "secret", "config_path": path})
    save_config(cfg, {"backend_name": "studio"})
    assert oct(os.stat(path).st_mode & 0o777) == oct(0o600)
    pub = cfg.public_dict()
    assert "secret" not in json.dumps(pub)
    assert pub["api_key_suffix"] == "cret"
