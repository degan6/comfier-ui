import sys
import types

from comfier_agent.cleanup import delete_file, delete_input_image


def test_deletes_output_and_temp_files(tmp_path, monkeypatch):
    output = tmp_path / "output"
    temp = tmp_path / "temp"
    output.mkdir()
    temp.mkdir()
    fp = types.ModuleType("folder_paths")
    fp.get_directory_by_type = lambda name: {"output": str(output), "temp": str(temp)}.get(name)
    monkeypatch.setitem(sys.modules, "folder_paths", fp)

    out_file = output / "comfier_00001_.png"
    out_file.write_bytes(b"data")
    temp_file = temp / "preview.png"
    temp_file.write_bytes(b"data")

    assert delete_file("comfier_00001_.png", file_type="output")
    assert delete_file("preview.png", file_type="temp")
    assert not out_file.exists()
    assert not temp_file.exists()


def test_deletes_uploaded_input_images_with_subfolders(tmp_path, monkeypatch):
    inp = tmp_path / "input"
    (inp / "comfier").mkdir(parents=True)
    uploaded = inp / "comfier" / "in.png"
    uploaded.write_bytes(b"data")
    fp = types.ModuleType("folder_paths")
    fp.get_directory_by_type = lambda name: {"input": str(inp)}.get(name)
    monkeypatch.setitem(sys.modules, "folder_paths", fp)
    assert delete_input_image("comfier/in.png")
    assert not uploaded.exists()
