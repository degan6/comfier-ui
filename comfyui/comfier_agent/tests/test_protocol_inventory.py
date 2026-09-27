from comfier_agent.inventory import models_from_object_info
from comfier_agent.jobs import collect_output_files
from comfier_agent.protocol import canonical_hash, find_unreplaced_placeholders, replace_input_refs


def test_inventory_hash_stable():
    def inv_hash(models, node_types):
        return canonical_hash({
            "models": {k: sorted(v) for k, v in sorted(models.items())},
            "node_types": sorted(node_types),
        })

    assert inv_hash({"checkpoints": ["a.safetensors"]}, ["A", "B"]) == inv_hash(
        {"checkpoints": ["a.safetensors"]}, ["B", "A"]
    )


def test_object_info_fallback_mapping():
    obj = {
        "CheckpointLoader": {"input": {"required": {"ckpt_name": (["x.safetensors", "y.ckpt"],)}}},
        "LoraLoader": {"input": {"required": {"lora_name": (["lora.safetensors"],)}}},
    }
    models = models_from_object_info(obj)
    assert "checkpoints" in models
    assert "loras" in models


def test_placeholder_detection():
    wf = {"3": {"class_type": "X", "inputs": {"image": "{{photo}}"}}}
    assert find_unreplaced_placeholders(wf) == ["{{photo}}"]


def test_input_ref_replacement():
    wf = {"3": {"class_type": "LoadImage", "inputs": {"image": "comfier-input://in_0"}}}
    out = replace_input_refs(wf, {"in_0": "comfier/file.png"})
    assert out["3"]["inputs"]["image"] == "comfier/file.png"


def test_output_walker():
    outputs = {
        "9": {"images": [{"filename": "a.png", "type": "output", "subfolder": ""}]},
        "10": {"mesh": [{"filename": "m.glb", "type": "output", "subfolder": ""}]},
        "11": {"gifs": [{"filename": "g.gif", "type": "temp", "subfolder": ""}]},
    }
    files = collect_output_files(outputs)
    assert len(files) == 2
    assert files[0]["filename"] == "a.png"

    only_temp = {
        "9": {"images": [{"filename": "t.png", "type": "temp", "subfolder": ""}]},
    }
    assert collect_output_files(only_temp)[0]["type"] == "temp"

    assert collect_output_files({}) == []
