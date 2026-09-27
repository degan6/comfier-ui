import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_sidecar_module_importable():
    proc = subprocess.run(
        [sys.executable, "-c", "import comfier_agent; print(comfier_agent.__version__)"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip()
