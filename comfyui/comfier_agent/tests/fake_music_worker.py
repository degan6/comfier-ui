"""Exercises the actual process boundary without MLX or model downloads."""
import json
import sys
import time
import wave

if "--inventory" in sys.argv:
    print(json.dumps({"version": "test", "models": ["yue2"], "catalog": ["yue2", "minimax-music3"]}))
elif "--download" in sys.argv:
    print(json.dumps({"event": "repo", "repo": "ahmadw/YuE2-3B-MLX"}), flush=True)
    print(json.dumps({"event": "done"}), flush=True)
else:
    recipe = json.load(sys.stdin)
    print(json.dumps({"event": "loaded"}), flush=True)
    if recipe["prompt"] == "wait forever":
        time.sleep(60)
    elif recipe["prompt"] == "worker error":
        print(json.dumps({"event": "error", "message": "inference failed"}), flush=True)
        sys.exit(1)
    elif recipe["prompt"] == "no output":
        sys.exit(0)
    else:
        output = sys.argv[sys.argv.index("--output") + 1]
        with wave.open(output, "wb") as audio:
            audio.setnchannels(2)
            audio.setsampwidth(2)
            audio.setframerate(48000)
            audio.writeframes(b"\0" * 1920)
        print(json.dumps({"event": "done"}), flush=True)
