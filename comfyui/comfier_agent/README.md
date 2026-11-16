# Comfier Agent

A ComfyUI custom node that connects **outbound** to a Comfier server and turns this ComfyUI into a Comfier worker.
ComfyUI needs no open port; the agent keeps one WebSocket open to Comfier, receives jobs, runs them on the local
ComfyUI, and uploads the results. It also downloads the models Comfier asks for and reports what's installed.

## Install

1. In Comfier, open **Servers → + Add a server**. Name it, choose who can use it, and choose **Add server and create
   a key**. Copy the key; Comfier only shows it once.
2. Copy this folder into ComfyUI's `custom_nodes` directory:

   ```bash
   git clone --depth 1 https://github.com/romkey/comfier-ui.git /tmp/comfier-ui
   cp -r /tmp/comfier-ui/comfyui/comfier_agent ComfyUI/custom_nodes/comfier_agent
   ```

   `aiohttp` ships with ComfyUI; there's nothing else to install. For preview images of 3D results (below), the agent
   also uses `numpy`, `Pillow` and `trimesh`; ComfyUI's 3D nodes usually bring them, or `pip install trimesh` in
   ComfyUI's environment.
3. Give it Comfier's URL and the key, either as environment variables before ComfyUI starts:

   ```bash
   export COMFIER_URL=https://comfier.example.com
   export COMFIER_API_KEY=cmf_...
   ```

   or with Docker:

   ```yaml
   environment:
     COMFIER_URL: https://comfier.example.com
     COMFIER_API_KEY: cmf_...
   ```

   or in the **Comfier** panel (below).
4. Restart ComfyUI. The server's setup page in Comfier updates when it connects.

## Install on a Mac (mflux, no ComfyUI needed)

On an Apple Silicon Mac the agent can run on its own, as a login service, and run image jobs with
[mflux](https://github.com/filipstrand/mflux), with or without ComfyUI. You need
[uv](https://docs.astral.sh/uv/) (`brew install uv`).

```bash
uv tool install --python 3.12 "comfier-agent[mac] @ git+https://github.com/romkey/comfier-ui.git#subdirectory=comfyui/comfier_agent"
comfier-agent setup            # Comfier's URL, this server's key, and whether this Mac runs ComfyUI too
comfier-agent service install  # starts now and at every login; restarts if it stops
```

The server's setup page in Comfier shows these lines with your URL and key filled in.

| Command | What it does |
|---|---|
| `comfier-agent setup` | Asks for Comfier's URL, the key, the server name, ComfyUI's URL (`none` if there isn't one) and the engines, and saves them to `~/.comfier/agent.json`. Takes `--url`, `--key`, `--name`, `--comfyui-url`, `--engines` and `-y` to skip the questions. |
| `comfier-agent service install` | Installs a launchd agent (`~/Library/LaunchAgents/com.comfier.agent.plist`) that starts at login and restarts on a crash. |
| `comfier-agent service status \| start \| stop \| restart \| uninstall` | Manages it. |
| `comfier-agent logs [-f]` | Shows `~/Library/Logs/comfier-agent.log`. |
| `comfier-agent doctor` | Checks the settings, Comfier and ComfyUI connections, the engines and their versions, memory and disk. |
| `comfier-agent pull MODEL` | Downloads an mflux model (for example `z-image-turbo`) by making a small test image, so the first real job doesn't wait for the download. |
| `comfier-agent lock -- COMMAND` | Runs a command while holding the GPU lock, so no Comfier job runs alongside it. |
| `comfier-agent run` | Runs in the foreground, which is what the service does. |

To update: `uv tool upgrade comfier-agent && comfier-agent service restart`. Comfier marks the server
**Update available** when there's a newer agent.

## The Comfier panel

ComfyUI's sidebar gets a **Comfier** tab. It shows whether the agent is connected, the server name, the Comfier URL,
the agent version, and whether it's taking jobs. When the connection fails, it says why: for example the key was revoked or replaced,
another ComfyUI is using the same key, or the agent is too old for this Comfier.

You can set the Comfier URL, API key, server name, and whether to share the queue from the panel. The saved key is
never shown again, only its last four characters. Changing the URL or key reconnects straight away. Settings go to
`comfier_agent.json` in ComfyUI's user directory (mode `0600`).

The panel's routes live under `/comfier-agent/` on ComfyUI. ComfyUI has no authentication, so anyone who can reach
ComfyUI's port can change them; keep that port off untrusted networks.

## Configuration

Environment variables override `comfier_agent.json`.

| Variable | Default | What it does |
|---|---|---|
| `COMFIER_URL` | *(required)* | Comfier's base URL. Must be `https` unless `COMFIER_ALLOW_INSECURE=true`. |
| `COMFIER_API_KEY` | *(required)* | This server's key from Comfier. |
| `COMFIER_BACKEND_NAME` | host name | Name reported to Comfier. |
| `COMFIER_COMFYUI_URL` | detected | Where the agent reaches ComfyUI, for example `http://127.0.0.1:8188`. |
| `COMFIER_ENABLED` | `true` | Set to `false` to load the node without connecting. |
| `COMFIER_SHARE_QUEUE` | `false` | Take Comfier jobs even while someone is using this ComfyUI directly. |
| `COMFIER_ALLOW_INSECURE` | `false` | Allow an `http` Comfier URL (development only). |
| `COMFIER_KEEP_OUTPUTS` | `false` | Keep result files in ComfyUI's output folder after uploading them. |
| `COMFIER_ALLOW_MODEL_DOWNLOADS` | `true` | Let Comfier ask this server to download models. |
| `COMFIER_MODEL_HOSTS` | any https host | Comma-separated hosts (and their subdomains) models may be downloaded from. |
| `COMFIER_MAX_DOWNLOAD_MB` | `200` | Largest input file (reference image, audio) the agent fetches for a job. |
| `COMFIER_UPLOAD_RETRY_SECONDS` | `600` | How long to keep retrying a result upload that fails with a network or server error. |
| `COMFIER_HEARTBEAT_SECONDS` | `10` | How often to send status. |
| `COMFIER_INVENTORY_POLL_SECONDS` | `60` | How often to check for added or removed models. |
| `COMFIER_INPUT_DIR`, `COMFIER_OUTPUT_DIR`, `COMFIER_MODELS_DIR` | ComfyUI's | Override ComfyUI's folders when the agent runs outside ComfyUI. |
| `HF_ENDPOINT` | — | Caching proxy or mirror base URL; rewrites `huggingface.co` / `hf.co` download links (like `huggingface_hub`). |
| `HF_TOKEN` | — | Used when Comfier did not send an `Authorization` header for a Hugging Face URL. |
| `HF_PROXY_TOKEN` | — | Optional token for the cache, sent on rewritten requests only. |
| `HF_PROXY_TOKEN_HEADER` | `X-Proxy-Token` | Header name for `HF_PROXY_TOKEN`. |
| `COMFIER_USE_HF_CLI` | `true` | Use the `hf` / `huggingface-cli` tool for Hub `/resolve/` links (falls back to HTTP). |
| `COMFIER_MAX_CONCURRENT_DOWNLOADS` | `1` | Parallel model downloads (`0` = no limit). |
| `COMFIER_ENGINES` | detected | Comma-separated engines to run: `comfyui`, `mflux`, `mlx_video`, `mlx_audio`. Default: ComfyUI plus whichever native image, video and audio runtimes are installed. Leave out `comfyui` on a Mac that doesn't run it. |
| `COMFIER_WORK_DIR` | `~/.comfier/work` | Where mflux and mlx-video jobs keep their inputs and results while they run. |
| `COMFIER_MLX_IDLE_UNLOAD_MINUTES` | `10` | Unload mflux's model after this long without a job (`0` keeps it loaded). |
| `COMFIER_MLX_VIDEO_IDLE_UNLOAD_MINUTES` | `10` | Unload MLX video's models after this long without a job (`0` keeps them loaded). Independent of the mflux timer. |
| `COMFIER_MLX_LOAD_TIMEOUT_SECONDS` | `3600` | How long loading an mflux or mlx-video model may take, including its first download. The job's time limit starts after. |
| `COMFIER_GPU_LOCK` | `true` | Hold `~/.comfier/gpu.lock` while a job runs, and take no jobs while another program holds it. |
| `COMFIER_HOME` | `~/.comfier` | Where a standalone agent keeps its settings (`agent.json`), work files and lock. |

`comfier_agent.json` also accepts `max_model_download_gb` (50), `min_free_disk_gb` (10), `max_concurrent_downloads`
(1), `use_hf_cli` (true), and `allow_pickle_formats` (true). When free space on a job or model volume falls below
`min_free_disk_gb`, the
server stops taking jobs and Comfier shows which path is low.

## What it sends

- **Status**: machine type, ComfyUI version, CPU, RAM, GPU, free disk, queue length, and the models installed.
- **Node list**: ComfyUI's `object_info`, compressed, so Comfier can check a workflow's nodes before sending it.
- **Results**: only image, video, audio and 3D files (`png`, `jpg`, `webp`, `gif`, `mp4`, `webm`, `mov`, `wav`,
  `mp3`, `flac`, `ogg`, `glb`, `gltf`, `obj`, `ply`, `fbx`). Anything else a workflow writes is skipped with a
  warning.
- **3D previews**: a 1024×1024 JPEG of a job's first 3D result (`glb`, `gltf`, `obj` or `ply`), for browsers that
  can't show the model. It's rendered on the CPU in a separate process, gives up after two minutes, and is skipped
  (with a warning in ComfyUI's log) when `trimesh` isn't installed or the model can't be read. FBX isn't supported.
- **Timings**: how long each phase of a job took, used for Comfier's time estimates.
- **Failures**: which node failed and ComfyUI's error, with out-of-memory errors called out.

Every message follows [`protocol/agent-v1.schema.json`](../../protocol/agent-v1.schema.json).

If the connection drops, the agent reconnects with backoff and tells Comfier which jobs are still running, so they
carry on. Finished and failed jobs that happened while disconnected are reported after reconnecting. Uploads that
fail with a network error or a 5xx or 429 response are retried for up to `COMFIER_UPLOAD_RETRY_SECONDS`.

## Versioning

The agent reports `__version__` from `comfier_agent/__init__.py` in every hello, and logs it when ComfyUI starts.
Comfier reads the same file from its own build and marks a server **Update available** when its agent is older, or
**Newer than Comfier** when it's newer. Bump `__version__` with every change to the agent, or Comfier can't tell
old agents from new ones. `pyproject.toml` takes its version from there.

## mflux on Apple Silicon

On a Mac the agent can run image jobs with [mflux](https://github.com/filipstrand/mflux) instead of
ComfyUI. It's faster and avoids ComfyUI's Mac problems. Install mflux next to the agent
(`pip install "comfier-agent[mflux]"`), and the agent reports the `mflux` engine to Comfier. Admins
then add mflux workflows (**Settings → Workflows → Runs on: mflux**), which only go to servers with
mflux and enough memory.

- **One job at a time.** A server runs one Comfier job whichever engine it's on.
- **Memory is handed over.** On Apple Silicon, ComfyUI and mflux share memory. Before an mflux job the
  agent asks ComfyUI to unload its models, and before a ComfyUI job it stops mflux. mflux also unloads
  after `COMFIER_MLX_IDLE_UNLOAD_MINUTES` without a job.
- **The model stays loaded.** mflux runs in a worker process that keeps the last model loaded, so only
  the first job with a model pays to load it. Cancelling a job ends the worker; the next job starts a
  new one.
- **Models download ahead, or on first use.** On the server's page in Comfier, a style whose model isn't
  on the Mac yet has a **Download** button (and **Download all** covers every style), which fetches
  exactly the files mflux uses without loading the model. Otherwise mflux fetches it during the first
  job, which then takes longer. The agent reports which models are already downloaded.
- **Models can be deleted from Comfier.** **Delete models** and **Reload models** on the server's page
  remove a model's Hugging Face repo from the cache (`HF_HUB_CACHE`, else `~/.cache/huggingface/hub`).
  For mflux that's the repo holding the model's weights; any other repos it fetched (a tokenizer, say)
  stay. For MLX video it's the style's `model_repo`, and its `text_encoder_repo` if it names one.
  Deleting needs `COMFIER_ALLOW_MODEL_DOWNLOADS` left on.
- **The GPU lock.** While a job runs the agent holds `~/.comfier/gpu.lock` (an `flock` lock). If another
  program holds it, the agent takes no jobs until it's released, so your own scripts can keep Comfier
  jobs off the GPU while they run.

To run mflux without ComfyUI at all, set `COMFIER_ENGINES=mflux` and run the agent as a sidecar (below).

## MLX video on Apple Silicon

Video jobs can run with [mlx-video](https://github.com/Blaizzy/mlx-video), which runs LTX-2 / LTX-2.3 /
LTX-2.5 (text, image and audio to video) and Wan2.1 / Wan2.2 natively. The `[mac]` install includes it; on its
own it's `pip install "comfier-agent[video]"`. It's installed from a pinned GitHub commit, because mlx-video
isn't on PyPI: for now the head of [Blaizzy/mlx-video#52](https://github.com/Blaizzy/mlx-video/pull/52), which
adds LTX-2.5 and isn't merged yet.

- A persistent worker runs mlx-video's command-line entry point (`mlx_video.ltx_2.generate` or
  `mlx_video.wan_2.generate`) with the recipe's flags and caches reusable model components between jobs.
  Progress comes from the tool's denoising bar. Prompt and seed changes reuse the warm weights;
  changes to the model, quantization, pipeline or other weight-affecting options restart the worker.
  LTX multi-stage/DFR pipelines reload their transformer each job because they merge LoRAs in place;
  their text encoder and VAE components can still stay warm.
- Video has its own idle timer: **10 minutes** after generation finishes by default. A new job resets it.
  Set `mlx_video_idle_unload_minutes` in `~/.comfier/agent.json`, or use
  `COMFIER_MLX_VIDEO_IDLE_UNLOAD_MINUTES` (which overrides the file); `0` disables idle unloading.
  This is separate from mflux's `mlx_idle_unload_minutes` / `COMFIER_MLX_IDLE_UNLOAD_MINUTES`.
  Restart the agent after changing settings. Switching to mflux unloads video immediately, regardless
  of either timer. Cancelling or failing a video job also ends its worker.
- Keeping components warm uses more memory than upstream's stage-by-stage unloading. The memory
  figures below describe the original cold pipeline; allow extra headroom with warm models.
- LTX recipes name a Hugging Face repo (`model_repo`, for example `prince-canuma/LTX-2.3-distilled`),
  which downloads on the first run. Wan loads weights already converted to MLX: either a folder on the Mac
  (`model_dir`, converted as mlx-video's README describes) or a Hugging Face repo of conversions (`model_repo`, with
  `model_subdir` for one variant in it). The agent fetches only that folder and hands mlx-video its path. The
  **Wan2.2 T2V A14B, 8-bit** preset loads `q8/` from `SceneWorks/wan2.2-t2v-a14b-mlx`: about 43 GB to download,
  and it needs a 64 GB Mac. Agent 0.4.14 or later is needed for `model_repo` with Wan.
- LTX-2.3 conversions don't include their text encoder, so LTX recipes also name one with
  `text_encoder_repo` (the presets use `mlx-community/gemma-3-12b-it-bf16`, about 26 GB). Comfier offers it
  for download alongside the model. Don't use `Lightricks/LTX-2` there: mlx-video then loads the wrong
  tokenizer and every prompt gives the same video.
- LTX-2.5 (`model_repo` `Lightricks/LTX-2.5`, distilled pipeline only) carries its own Gemma 4 text encoder and
  upscaler, so its recipes don't name a `text_encoder_repo`. It's much better at following the prompt than
  LTX-2.3. The repo is gated: accept its terms on Hugging Face, then run `hf auth login` on the Mac. The agent
  downloads only the files the distilled pipeline reads, about 73 GB of the repo's 200 GB.
- `"quantize": 8` in an LTX-2.5 recipe (the 8-bit presets) has the agent quantize the transformer and text
  encoder as they load. A 5-second 1280×704 job then peaks at about 29 GB instead of 46 GB and looks the same, so
  it runs on 48 and 64 GB Macs. mlx-video has no such flag, so the agent applies it itself (only LTX-2.5). The
  first such job saves the quantized weights to `~/.comfier/quantized` (about 34 GB at 8 bits;
  `COMFIER_MLX_QUANTIZED_DIR` moves it) and later jobs load those, which is quicker than quantizing again. A
  re-downloaded checkpoint gets a fresh copy; if the folder can't be written, jobs quantize every time instead.
- The agent caps MLX's buffer cache at 4 GB for video jobs. Without the cap it grows to about 56 GB while LTX
  decodes video, though only a few GB are in use, which pushed a job's peak to 69 GB. Output is unchanged.
- Memory matters: LTX-2.3 and LTX-2.5 are 22B video models plus a 12B text encoder, so plan on 96 GB, or 48 GB
  for LTX-2.5 at 8 bits. Wan2.2 TI2V 5B
  fits in 32 GB. Set `min_memory_gb` in the recipe and Comfier only sends the style to Macs with that much.
- The agent works around an mlx-video bug that makes LTX videos come out black on some Macs
  ([Blaizzy/mlx-video#55](https://github.com/Blaizzy/mlx-video/issues/55)).
- Before uploading, the agent moves the MP4's index to the front with `ffmpeg -c copy -movflags +faststart` (no
  re-encoding), so browsers can start playing right away. Without ffmpeg the file goes as is and Comfier fixes it.
- The one-job-at-a-time rule, the GPU lock and the memory handover with ComfyUI and mflux apply to video
  jobs too.

## fp8 models on Apple Silicon

PyTorch's MPS device can't hold fp8 tensors, so ComfyUI on a Mac fails on fp8 checkpoints such as Wan 2.2's
`*_fp8_scaled.safetensors`. Comfier swaps them for fp16 on Apple Silicon servers. If the official fp16 file is
published beside the fp8 one (`…_fp16.safetensors`), Comfier downloads that. Otherwise the agent downloads the fp8
file and saves it as `…_fp16_from_fp8.safetensors`, and jobs sent to the Mac use whichever fp16 file it has.
Conversion needs numpy (ComfyUI ships it), keeps one tensor in memory at a time, and needs free disk space for both
files until it finishes. The fp16 file is about twice the size of the fp8 one.

## Sidecar mode

The agent can also run as its own process next to ComfyUI instead of inside it (on a Mac, the
service above does this):

```bash
pip install ./comfyui/comfier_agent
comfier-agent run --comfyui-url http://127.0.0.1:8188
```

Set `COMFIER_INPUT_DIR`, `COMFIER_OUTPUT_DIR` and `COMFIER_MODELS_DIR` if it can't find ComfyUI's folders.

## Testing

The tests run the agent against a fake Comfier and a fake ComfyUI (no GPU or ComfyUI install needed) and validate
every message against the protocol schema:

```bash
python3 -m venv /tmp/comfier-venv
/tmp/comfier-venv/bin/pip install -e ".[test]" ruff
/tmp/comfier-venv/bin/ruff check comfier_agent tests && /tmp/comfier-venv/bin/pytest -q
```

The end-to-end test in the main repository runs this agent against real Rails, Sidekiq and Redis:

```bash
docker compose -f docker-compose.test.yml run --rm e2e
```

### Manual smoke test with a real ComfyUI

1. Start Comfier: `docker compose -f docker-compose.dev.yml up`, and sign in at <http://localhost:3000>.
2. Add a server under **Servers → + Add a server** and copy the key.
3. On the ComfyUI machine, install the agent as above with `COMFIER_URL` set to an address that machine can reach
   (for example `http://your-mac.local:3000`) and `COMFIER_ALLOW_INSECURE=true`, since the dev server is plain http.
4. Restart ComfyUI. The setup page should switch to connected, and the server's page should list its models.
5. Generate an image with a style whose models the server has. Watch progress on the result card, and check the
   result appears and the job shows on the server's page.
6. Stop ComfyUI mid-job and start it again: the job should be recovered and either resume or be retried.

## Security

- Anyone with this server's key can run arbitrary workflows on it, and custom nodes can run arbitrary code. Issue one
  key per server, and revoke keys you no longer use (**Servers → your server → Keys**).
- Whoever owns a server can see the prompts, images and results of every job that runs on it. Comfier warns people
  before their job runs on someone else's server.
- Download tokens you add in Comfier are only sent to the matching site and its subdomains. When a download redirects
  to another host, the agent drops every credential header.

## MiniMax Music 3 on Apple Silicon

The `mlx_audio` engine runs MiniMax Music 3 with [mlx-audio](https://github.com/Blaizzy/mlx-audio), the same BF16
MLX pipeline as YuE Studio. It does not need ComfyUI, and there is nothing extra to install: the `[mac]` extra
includes mlx-audio. On a Mac that already runs the agent, update it (`uv tool upgrade comfier-agent`), then run
`comfier-agent setup` again and accept the detected engines, or add `mlx_audio` to `engines` in
`~/.comfier/agent.json`, and restart the service. The engine is only offered when the installed mlx-audio has
MiniMax Music 3 (0.6.3 or later); `comfier-agent doctor` shows the version.

In **Settings → Workflows**, choose **MLX audio** and the **MiniMax Music 3 vocals** or **instrumental** preset.
These use a fixed 60-second maximum, base 20 steps (Fast/Standard/Best = 10/20/30), and a 96 GB memory requirement.
The memory requirement is a conservative starting estimate: a 60-second, 20-step BF16 run measured about 60.6 GB
peak MLX allocation. It is not a full-length memory guarantee. Admins can edit the recipe's duration from 0.04 to
300 seconds; length controls in the generation form are separate work. The model may stop early or be cut off
at the maximum. Vocal recipes require lyrics; instrumentals condition on `[Instrumental]`, without guaranteeing
that every output is vocal-free. Existing ComfyUI workflows are not converted automatically.

MiniMax's sound controls have one source: literal numbers in the recipe JSON:

```json
"semantic_guidance": 1.5,
"acoustic_guidance": 1.7,
"top_k": 50
```

Semantic guidance controls the autoregressive musical tokens; acoustic guidance controls waveform synthesis.
`top_k` controls token sampling in the semantic and residual codebooks (each stage clamps it to its vocabulary).
Both guidance values accept 0–10; `top_k` accepts whole numbers from 1–16384. Omitted keys keep the defaults above.
These keys do not accept placeholders such as `{{cfg}}`. Quality adjusts `{{steps}}` only, without scaling either
guidance value or top-k. The unrelated Default guidance, Base resolution and Frame rate fields are hidden for
MLX audio. Other engines keep their existing fields. mlx-audio has no arguments for these controls, so the worker
sets them inside each job's own process; the installed package is not modified.

The worker pins `mlx-community/MiniMax-Music3-bf16` revision `83a5f2d365673689df5c8f36e21e108751fd92ea`. The model is about
28.5 GB. Download it from the server's workflow list before a run, or let the first run download it. Inventory
only marks the pinned revision ready when its config, tokenizer and every weight shard are present.

Each job is a separate, cancellable process. The existing single job slot, memory handover and cooperative GPU
lock apply; other apps must use the same lock to cooperate. Progress reports loading and running, without an
invented percentage. The worker preserves the explicit seed and the runtime's actual sample rate
(currently 44.1 kHz stereo), uploads a lossless WAV master, and adds an MP3 V0 derivative when FFmpeg is available.
An MP3 export failure keeps the WAV. Effective model/runtime versions, seed, steps, duration and memory metrics
are written to the agent's log when each job finishes.
Review the [MiniMax model license](https://huggingface.co/mlx-community/MiniMax-Music3-bf16/blob/main/LICENSE)
when installing the weights. YuE2 and score planning are not implemented in this engine yet.

## YuE2 on Apple Silicon

Agent 0.4.18 or later also runs [YuE2 through mlx-Yue](https://github.com/vanch007/mlx-Yue).
The `mlx_audio` engine generates 48 kHz stereo music from a style prompt and lyrics, with optional ABC score conditioning.
The presets use 8-bit planning, BF16 acoustic synthesis, and a three-minute maximum. Start with a Mac
with 32 GB of memory; this is a conservative scheduling threshold, not a measured guarantee.

YuE2's pinned runtime requires Python 3.12 and MLX 0.32.2, which conflicts with MiniMax's newer MLX.
Install it in a separate environment, from the repository root:

```sh
uv venv --python 3.12 ~/.comfier/yue2
uv pip install --python ~/.comfier/yue2/bin/python './comfyui/comfier_agent[yue2]'
```

The agent detects `~/.comfier/yue2/bin/python` automatically. To use another location, set
`COMFIER_YUE2_PYTHON` to its absolute Python path in the agent process's environment. This environment
needs the `comfier-agent[yue2]` package as well as the MLX runtime; it does not need mflux or mlx-video.
The `[mac]` extra continues to install the image, video and MiniMax runtimes in the main environment.
Run `comfier-agent setup` again to enable `mlx_audio`, or add it to the existing `engines` setting,
then restart the agent. `comfier-agent doctor` reports each music runtime independently.

In **Settings → Workflows**, choose **MLX audio** and the **YuE2 vocals** or **YuE2 instrumental** preset.
Download `vanch007/mlx-Yue2-3B` from the server's model controls, or prefetch it in the agent's environment:

```sh
~/.comfier/yue2/bin/python -m comfier_agent.workers.yue2 --download vanch007/mlx-Yue2-3B
```

The worker pins model revision `5f7620e546fb3c6130a09a7e18172e3bb7aaeddb` and mlx-Yue commit
`c5b5a8190f78c74aa671a4caa19dae8b8e04b3d8`. The download includes both AR precisions, the acoustic
model and VAE (about 10.5 GB); BF16 AR weights are also required for acoustic conditioning in 8-bit mode.
Use the same `HF_HOME` / `HF_HUB_CACHE` for prefetching and running the agent. Complete cached snapshots
work offline. The worker materializes temporary hardlinks for the pipeline's integrity checks; across
filesystems it falls back to copies, requiring another 10.5 GB of free space during a job.

The recipe accepts these controls:

- `style` and `lyrics`: normally `{{prompt}}` and `{{lyrics}}`. Instrumental presets use `[Instrumental]`.
- `duration`: maximum seconds, from 0.04 to 360, expressed as a 25 Hz semantic token budget. Songs may end sooner.
- `steps`: acoustic refinement steps, from 1 to 64. The presets use `{{steps}}` with a base of 32,
  giving Fast/Standard/Best 16/32/48 steps.
- `seed`: the usual `{{seed}}`, preserved through planning and synthesis.
- `precision`: `8bit` (default) or `bf16` for the planning model.
- `cot`: `full` (default, melody and chords), `melody`, or `off` for direct generation.
  This setting does not select instrumental music.
- `abc`: optional nonempty ABC notation, with `cot` set to `full` or `melody`.
- `cfg_scale`: optional literal guidance from 0 to 20. Defaults to 1.0 with score planning and 1.01
  in direct mode. Presets explicitly set 1.0; remove it to use the mode-specific default when changing `cot`.

### YuE2 score and audio sampling in workflow JSON

Agent **0.4.19 or later** accepts the following independent sampling controls. Prefix each field with
`abc_` for score composition or `semantic_` for audio-token generation. These are literal JSON numbers
in the admin workflow recipe, independent of generation Quality or the hidden generic guidance field.
No new end-user generation controls are added. Omitted fields preserve the original pipeline defaults.

| Field suffix | Score (`abc_`) default | Audio (`semantic_`) default | Allowed values |
| --- | --- | --- | --- |
| `temperature` | 0.7 | 1.0 | Finite number, 0–5; 0 uses greedy sampling |
| `top_p` | 0.9 | 0.95 | Finite number, greater than 0 and at most 1 |
| `top_k` | 30 | 100 | Integer, at least 1 |
| `repetition_penalty` | 1.005 | 1.2 | Finite number, greater than 0; 1 disables the penalty |
| `penalty_window` | 100 | 50 | Integer, 1–100 tokens |
| `min_tokens` | 32 | `min(200, effective semantic_max_tokens)` | Integer, 0–24575, no greater than the stage's maximum |
| `max_tokens` | 4096 | `max(1, floor(duration * 25))` | Integer, 1–24575; audio is additionally capped by duration |

For example, these fields can be added to either vocal or instrumental recipes:

```json
{
  "abc_temperature": 0.7,
  "abc_top_p": 0.9,
  "abc_top_k": 30,
  "abc_repetition_penalty": 1.005,
  "abc_penalty_window": 100,
  "abc_min_tokens": 32,
  "abc_max_tokens": 4096,
  "semantic_temperature": 1.0,
  "semantic_top_p": 0.95,
  "semantic_top_k": 100,
  "semantic_repetition_penalty": 1.2,
  "semantic_penalty_window": 50,
  "semantic_min_tokens": 200
}
```

Presets include these defaults so admins can discover and edit them directly. `semantic_max_tokens`
is omitted from presets so changing `duration` adjusts the upper bound automatically. An explicit
`semantic_max_tokens` can shorten that budget, but cannot exceed `max(1, floor(duration * 25))`.
If an explicit minimum exceeds its stage's maximum, validation rejects the recipe. In particular,
when shortening a preset below eight seconds, lower or remove its explicit `semantic_min_tokens: 200`.
Minimum tokens prevent an early end token; they do not guarantee musical completeness or an exact
recording length. The ABC token budget counts notation tokens, not seconds.

Score sampling applies only when `cot` is `full` or `melody` and no `abc` score is supplied. With
`cot: "off"` or a supplied score, the composition stage is skipped; audio sampling still applies.
Both stages must leave room for their prompt and score prefixes within the model's 24576-token
context. The runtime checks the exact tokenized prefix; a large ABC budget can hit that limit even
when the recipe's individual numeric ranges are valid. Completed jobs log both effective sampling
configurations, including duration-derived limits, for reproducibility.

Jobs use the same GPU lock, load/run timeouts, cancellation and uploads as the other Mac engines.
The master recording is a 24-bit WAV. Review the [model license and notices](https://huggingface.co/vanch007/mlx-Yue2-3B)
before use.
