"""Messages the agent builds must match protocol/agent-v1.schema.json (the frontend validates the same file).

The integration tests go further: FakeFrontend checks every message the running agent sends.
"""

import base64
import gzip
import json
import os

import pytest
from fake_frontend import VALIDATOR, schema_errors

from comfier_agent.comfy_client import flatten_ws_event
from comfier_agent.jobs import failure_message
from comfier_agent.protocol import OBJECT_INFO_MAX_CHUNKS, compact, encode_object_info


def test_schema_itself_is_valid():
    VALIDATOR.check_schema(VALIDATOR.schema)


def test_schema_rejects_a_null_optional_field():
    assert schema_errors({"type": "model.download.progress", "download_id": "d_1", "bytes_total": None})
    assert not schema_errors(compact({"type": "model.download.progress", "download_id": "d_1", "bytes_total": None}))


def test_object_info_chunks_reassemble_like_the_frontend():
    info = {f"Node{i}": {"input": {"required": {"x": [[f"opt{j}" for j in range(50)]]}}} for i in range(300)}
    chunks = encode_object_info(info, "sha256:abc", chunk_chars=1000)
    assert len(chunks) > 1
    for chunk in chunks:
        assert not schema_errors(chunk)
        assert (chunk["hash"], chunk["count"]) == ("sha256:abc", len(chunks))
    # Frontend: join data in index order, base64-decode, gunzip.
    joined = "".join(c["data"] for c in sorted(chunks, key=lambda c: c["index"]))
    assert json.loads(gzip.decompress(base64.b64decode(joined))) == info


def test_object_info_refuses_more_chunks_than_the_frontend_accepts():
    info = {"x": os.urandom(4000).hex()}
    assert len(encode_object_info(info, "h", chunk_chars=10_000)) == 1
    with pytest.raises(ValueError):
        encode_object_info(info, "h", chunk_chars=5_000 // OBJECT_INFO_MAX_CHUNKS)


def test_failure_messages_match_the_schema():
    msg = failure_message("j_1", "validate", "bad", {"inputs_ms": 3}, node_errors={"3": {"errors": []}}, node=None)
    assert not schema_errors(msg)
    msg = failure_message("j_1", "execute", "x" * 5000, {}, node=12, exception_type="RuntimeError",
                          traceback_tail="t" * 20000)
    assert not schema_errors(msg)


def test_comfyui_events_are_flattened():
    event = flatten_ws_event({"type": "executing", "data": {"node": "3", "prompt_id": "p_1"}})
    assert event == {"node": "3", "prompt_id": "p_1", "type": "executing"}
    assert flatten_ws_event({"type": "status"})["type"] == "status"
    assert flatten_ws_event("nonsense") == {}
