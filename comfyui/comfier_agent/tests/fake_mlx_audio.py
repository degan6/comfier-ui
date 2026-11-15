"""Subprocess fixture for MLX audio; records the exact request beside a small WAV."""
import argparse
import json
import time
import wave
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--probe', action='store_true')
parser.add_argument('--download')
parser.add_argument('--request', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
model = 'mlx-community/MiniMax-Music3-bf16'
if args.probe:
    print(json.dumps({'version': '0.4.0', 'models': [model], 'catalog': [model]}))
elif args.download:
    print(json.dumps({'event': 'repo', 'repo': model}))
    print(json.dumps({'event': 'done'}))
else:
    data = json.loads(args.request.read_text())
    print(json.dumps({'event': 'loaded'}), flush=True)
    time.sleep(.7)
    if data['caption'] == 'hang':
        time.sleep(60)
    if data['caption'] == 'fail':
        raise ValueError('bad native waveform')
    with wave.open(str(args.output), 'wb') as out:
        out.setparams((2, 2, 44100, 0, 'NONE', 'not compressed'))
        out.writeframes(b'\x01\x00\x02\x00' * 4410)
    args.output.with_suffix('.request.json').write_text(json.dumps(data))
    print(json.dumps({'event': 'done', 'sample_rate': 44100}), flush=True)
