# Plan: Comfier frontend — remaining agent work

This plan covers everything from "Comfier frontend — backends, queues, model provisioning, and
predictions" that the first implementation pass did not finish. Section numbers like "§5" refer to
that plan, and its wire formats (and `comfier-agent-node-plan.md`) are still authoritative.

Each phase is one PR into `staging`, shippable on its own. Phase 0 must land first, because
without it the agent job path does not work outside tests.

---

## Where things stand

**Built:** the migration, `BackendKey` and `cmf_` keys, `Agent::Hub`, `/api/agent/ws`
(`Agent::WebsocketApp`), `Agent::MessageHandler`, pull dispatch with a compare-and-set update,
a router that scores by queue length, `Agent::Submission` (filled workflow, `comfier-input://in_0`),
the input and output endpoints, download planning and sending, and 16 service tests.

**Stubs that do nothing yet:** `Presence.publish!`, `Presence.mark_offline!`, `LoadMinute.record!`,
`CredentialHeaders.for_url`, and `Availability.recompute_for_backend!` (it computes results and
throws them away).

---

## Phase 0 — Fix what's broken

These bugs make the current code wrong. They are not missing features.

### 0.1 The Hub only exists in the web process
`Agent::Hub` is in-memory, but `SubmitGenerationJob`, `ReconcileBackendJob`, and
`AssignAckTimeoutJob` run in the Sidekiq container. There, the Hub is always empty, so:
- `Presence.online?` is false for every agent backend. `BackendSelector` and `Router` treat all of
  them as offline, and every agent job fails as unroutable.
- `Dispatcher.dispatch_for!` and `Hub#send_message` quietly do nothing. The agent's open
  `job.request` is never answered.

**Fix (decided: Redis):** keep the web process as the only owner of sockets, and connect the two
processes through Redis, which is already deployed:
- **Presence in Redis.** On every `status` and `hello`, write `agent:presence:<backend_id>` holding
  the state, `accepting`, `disk_free`, and `vram_free`, with a TTL of `OFFLINE_AFTER_S`. Also write
  `agent:open_request:<backend_id>`. `Presence` reads from Redis, so any process gets the same
  answer. The Hub keeps sockets only.
- **Commands over pub/sub.** Add an `Agent::Commands` interface with `send_message(backend_id, msg)`
  and `dispatch(backend_id)`. In the web process it calls the Hub directly. Elsewhere it publishes
  to `agent:commands`, and a subscriber thread started from an initializer (web process only) runs
  the command. This is the `AgentHub`/`Dispatcher` seam described in §2's scaling note.
- `Dispatcher` checks for an open request through Redis. The compare-and-set update stays in
  Postgres, so there's still no double dispatch.
- Test both paths: one in-process, and one where a "remote" caller publishes a command and the
  subscriber dispatches it.

### 0.2 Routing runs twice for agent jobs
`SubmitGenerationJob` calls `BackendSelector` first (legacy logic, `enabled` backends only), then
`Router`. Instead, send the job to `Agent::Submission` whenever the user can see any agent
backends, and keep `BackendSelector` for legacy backends only. §11 wraps both behind one interface
later.

### 0.3 A re-route pins the job to the backend it should avoid
`JobLifecycle.reroute!` sets `pinned_backend_id: exclude.id`. Add `excluded_backend_ids`
(a jsonb array on `generations`, cleared when the job moves to a new attempt), make `Router` skip
those backends, and leave `pinned_backend_id` for the user's "Run on" choice.

### 0.4 The `backend_inventories.hash` column
It overrides `Object#hash` on the model, and `MessageHandler#handle_inventory` compares against it.
Rename it to `inventory_hash`. The migration hasn't been merged, so edit it in place and
regenerate `db/schema.rb`.

### 0.5 WebSocket limits aren't enforced
- The `hello` deadline is only checked when a message arrives, so a silent connection stays open
  forever. Add an EventMachine timer (`EM.add_timer`) that closes the socket if no `hello` arrived.
- Messages over 1 MB are dropped, but §2 says to close with code `1009`. Check `raw.bytesize` before
  parsing.
- Revoking a key doesn't close the live socket with `4401` (that ships with Phase 1's revoke action).

### 0.6 Validate against the real schema
`ProtocolValidator` hand-checks a few fields. Add the `json_schemer` gem and validate every inbound
message against `protocol/agent-v1.schema.json`. Keep the size check and the known-type check.
Contract test: every message the frontend builds (`job.assign`, `model.download`, `job.cancel`,
`config.*`, `inventory.refresh`, `object_info.request`) validates. Add a test that fails if the
Rails and agent copies of the schema differ.

### 0.7 Stream inputs
`JobsController#input` calls `blob.download`, which loads the whole file into memory. Stream it
instead (`send_blob_stream`, or a redirect to a short-lived service URL), with `Content-Length`.

---

## Phase 1 — Server registration, keys, and server pages (§1, §9 UI)

### Models and settings
- `AppSetting#allow_user_backends` (the column exists), plus `backend_roles` (an array of group
  names). Admins can always register servers.
- A policy object `BackendPolicy` with `can_register?`, `can_manage?(backend)`, and
  `can_use?(backend)`, covering private, shared, and public visibility (§4). Everything else calls
  it, including `Router`'s visibility query.
- Sharing is with individual users only (decided). `BackendShare` already covers that. The share
  list is a user picker on the server settings page. Group sharing is out of scope.

### Keys
- **Rotate:** issue a new key, and set `expires_at = 24.hours.from_now` on the old one, or
  `revoked_at = now` if the owner picks "revoke immediately".
- **Revoke:** set `revoked_at` and send `Agent::Commands.close(backend_id, 4401)`.
- **Rate limit:** Rails 8 `rate_limit to: 5, within: 1.hour` on create and rotate.
- **Rejected attempts:** when `Authenticator` rejects a known prefix (revoked or expired), write
  `backend_keys.last_rejected_at` and `last_rejected_reason`, so the setup page can show why a
  connection failed.

### Pages (Bootstrap + `refresh.css` classes from `ui.mdc`)
- `BackendsController` (user-facing, `/servers`) and extend `Admin::BackendsController`.
- **Servers list:** a `.table-compact` of servers the user can use. Columns: name, owner, an
  availability dot (a badge only for exceptional states), GPU and VRAM, queue length, "typical
  wait" (Phase 6, shows "—" until then), relative speed (Phase 6), and which of the user's
  workflows it can run (Phase 3). Hide `system_json` from non-owners.
- **Add a server:** name, description, visibility, and a share list. On save, show the key once
  with a copy button and "You won't be able to see this key again.", then install instructions with
  the frontend URL filled in: git clone into `custom_nodes/`, the settings panel, the
  `COMFIER_URL`/`COMFIER_API_KEY` environment variables, and a Docker `environment:` snippet.
- **Waiting for connection:** a Turbo Stream subscription on `[backend, :presence]`. When `hello`
  arrives, show GPU, VRAM, ComfyUI version, model count, node-type count, and "Your server is
  connected." After 2 minutes with nothing, show the troubleshooting checklist. Show the
  rejected-key reason if there is one.
- **Server detail (owner and admins):** hero with live status; current job and progress; the
  queue, where non-admin owners see other users' jobs as workflow plus display name only, with no
  prompts; downloads; an inventory browser (models by folder, node types, searchable); keys;
  policies (`owner_priority`, `max_queued_per_other_user`, `allowed_workflow_ids`,
  `auto_download_policy`); pause and resume (sends `config.pause`/`config.resume`, and Router skips
  paused servers). Performance and charts come in Phases 6 and 7.
- **Flapping:** show "This key appears to be in use on two machines" when `Hub#flapping?` is true.
  Store the replacement count in Redis so Sidekiq-rendered broadcasts can see it.
- **Delete server:** soft-delete with `deleted_at`, revoke its keys, close with `4401`, re-route
  queued and waiting jobs, and treat the running job as lost (Phase 5). Keep history.

### Audit
Use the existing `ActivityLog` for: key created, rotated, revoked; server shared or unshared;
policy changes; downloads requested.

### Tests
Policy matrix; one-time key display; rotation grace (old key works before `expires_at` and fails
after, using `travel_to`); revoke publishes a `4401` close; rate limit; rejected-attempt hint;
anonymized queue for owners who aren't admins; a system test for the add-server flow.

---

## Phase 2 — Live status push (§2 "status", §9 Live)

- `Presence.publish!` debounces to one broadcast per backend per second, using a Redis `SET NX EX 1`
  key. Broadcast Turbo Stream replacements to `[backend, :presence]` (server pages and list rows)
  and `[user, :generations]` (job cards). The app already uses `broadcast_*_later_to`.
- Payload: availability, current job and progress, queue length, downloads, `vram_free`,
  `disk_free`.
- `Presence.mark_offline!` (after `bye`) deletes the Redis presence key and broadcasts
  immediately.
- A job every 10s (`OfflineSweepJob`) finds agent backends whose presence key expired since the
  last run, records `offline_since`, broadcasts, and starts the lease clock (Phase 5).
- Persist `last_status_json` at most every 30s. Today it never persists: `handle_status` bumps
  `updated_at` (via `last_seen_at`) just before checking whether `updated_at` is 30s old. Track a
  separate `last_status_persisted_at` and test it.
- Tests: offline after `OFFLINE_AFTER_S` without status; `bye` is immediate; every agent state maps
  to the right label; the debounce collapses a burst into one broadcast.

---

## Phase 3 — Workflow requirements and availability (§3)

- **Store both forms:** the workflow import saves the UI form in `workflows.ui_graph` (the column
  exists). `Requirements.extract!` runs on save when the graph changes.
- **Extraction fixes:**
  - Match UI metadata to API references by exact filename, then by basename.
  - Use the UI `directory` when the API folder is `unknown`.
  - Use the UI `hash` as `sha256` when `hash_type == "sha256"`.
  - Read the top-level `models` array.
  - Add the missing `unknown` folder fallback.
- **`structure_hash`:** sha256 of the canonical API form (keys sorted recursively) with placeholders
  kept as placeholders. The current version doesn't sort keys.
- **`WorkflowModel` table** (instead of only `requirements_json`): `folder`, `filename`, `url`,
  `sha256`, `bytes`, `source`. Admin edits are stored with `source: "admin"` and are merged over
  re-extracted rows by `(folder, filename)`.
- **Enrichment:** `EnrichWorkflowModelsJob` sends a `HEAD` to Hugging Face `resolve` URLs and reads
  `X-Linked-Etag` and `X-Linked-Size`. For other hosts it reads `Content-Length`. Rows get
  `source: "enriched"`. Stub these with WebMock in tests.
- **`object_info`:** reassemble chunks per `object_info_hash` (hold partial chunks in Redis with a
  TTL), then gunzip and store in a `backend_object_infos` table (`backend_id`, `hash`, `blob_gz`).
- **Matching:**
  - Folder aliases already exist.
  - Add the "present at a different path" hint: the basename exists in another subdirectory. It
    still counts as missing, and the path found is shown to the admin.
  - Strict check: when `object_info` is cached, every literal list-typed input must be in its
    options, except models being downloaded right now.
- **Availability:** include the `disk_free` check for `needs_downloads`. Cache results in a
  `workflow_availabilities` table (`workflow_id`, `backend_id`, `status`, `details_json`). Recompute
  when the inventory hash changes, when requirements change, and when a download completes.
- **UI:** the requirements list on the workflow admin page, with folder, URL, and sha256 editing;
  an availability matrix (workflows × servers) on the workflow admin page and on each server page,
  showing ready, needs downloads (with size), or blocked (with the reason). "Prepare servers" is in
  Phase 4.
- **Data migration:** a rake task (`bin/rails agent:extract_requirements`) runs extraction on all
  workflows and flags those with `unknown` folders or missing URLs for admin review.
- Tests: every §3 scenario (input-name mapping, UI join by basename, admin overrides surviving
  re-extraction, mocked HEAD enrichment, aliases, subdirectory mismatch, strict enum).

---

## Phase 4 — Model downloads (§5)

- **`SourceCredential`:** `owner_user_id` (null means global), `host`, `secret` (encrypted with
  `encrypts`), `label`, `last4`. Admin page for global credentials, and a user settings page for
  their own. Only `last4` is shown after saving.
- **`CredentialHeaders.for_url`:** match the URL host (including subdomains, e.g.
  `cdn-lfs.huggingface.co` for `huggingface.co`); use the backend owner's credential, then the
  global one. Tests cover host mismatch, owner-first order, and the global fallback.
- **Manual downloads:** add a server picker to the existing download UI (servers the user owns, or
  any server for admins). For agent backends, `ModelDownload` goes through `DownloadPlanner`
  instead of the downloader-node or Manager path.
- **"Prepare servers"** on the availability matrix: create downloads for every missing model on the
  selected servers.
- **Sending:**
  - One download in flight per backend, already done.
  - Queue order: downloads for waiting jobs first, then FIFO.
  - The disk check uses `disk_free` from Redis presence.
  - Backends that are offline get their queued downloads after `hello`, already done in
    `Reconciliation`.
- **Events:**
  - Human-readable failure messages for every reason in §5's table, including the 401/403 → "check
    the access token for <host>" case.
  - On failure or cancel, re-route each waiting job with this backend excluded, or fail it with the
    download message.
  - Update `TransferStat(kind: "download", host)` (Phase 6 table; write the EWMA now if it's ready).
- **Cancel:** a user or admin cancel sends `model.download.cancel`.
- **Download UI:** a per-server list with progress, speed, ETA, and cancel. Job cards in
  `waiting_models` show "Downloading models on <server>: 3.1 of 6.9 GB, about 4 min".
- Tests: every §5 and test-plan §12 scenario, including deduplication, the one-in-flight throttle,
  disk failure without sending, resend on reconnect, releasing waiting jobs, and each
  `auto_download_policy`.

---

## Phase 5 — Job lifecycle completeness (§6)

### Attempts and retries
- A `job_attempts` table: `generation_id`, `attempt`, `backend_id`, `outcome`, `reason`,
  `timings_json`, `warm`, `predicted_execute_ms`, `started_at`, `ended_at`. Write a row for every
  terminal event, rejection, and lost job.
- The `MAX_INFRA_RETRIES` budget counts infrastructure attempts from this table, not
  `agent_attempt`.

### Failures (`job.failed`)
- `validate` where the node errors mention a model value not in its list → send
  `inventory.refresh`, re-route once.
- `validate` (other) → fail, showing `node_errors` as "Node 7 (KSampler): …".
- `execute` out of memory (`OutOfMemory` / `CUDA out of memory`) → re-route to an eligible backend
  with more `vram_total` if attempts remain; otherwise "The server ran out of GPU memory. Try a
  smaller size or fewer frames."
- `execute` (other) → fail with the error, node, and exception type. `traceback_tail` is shown to
  admins and the server owner only.
- `inputs` or `outputs` → retry once if the budget allows.

### Cancel
- `routing`, `queued`, or `waiting_models` → compare-and-set to `cancelled`, remove the job from
  `for_generation_ids`, and let automatic downloads keep running.
- Active states → `cancelling`, send `job.cancel`, and schedule `CancelTimeoutJob` for
  `CANCEL_TIMEOUT_S`.
- Wire `GenerationCanceller` to this path for agent backends.

### Leases and reconciliation
- `LeaseSweepJob` (every 15s): a backend offline for `LEASE_GRACE_S` →
  - its active job is lost (record the attempt; re-route to the head of the chosen queue, or fail
    with "The server went offline while running this job.");
  - its `queued` and `waiting_models` jobs are re-routed, except pinned jobs and jobs from
    "My servers only" users.
- Reconciliation step 1 (missing today): `hello.active_jobs` entries that are unknown, cancelled,
  or reassigned get `job.cancel`. Entries still assigned here update the job's state.
- Only treat jobs as lost when no terminal event arrived during `RECONCILE_WAIT_S`. Track the
  last terminal-event time per job.

### Routing and queue
- Queue order: when owner priority applies, the owner's jobs come first, then `queue_order`. A
  requeue goes to the head (negative `queue_order`, so several requeues keep their relative order).
- "My servers only" with every server offline: leave the job in `routing` and show "Waiting for
  your server to come online". When one of the user's servers sends `hello`, route its waiting jobs.
- Unroutable jobs fail with a reason per backend. A "No servers you can use are online" message
  covers the empty case.
- Ties: prefer the user's own backend, then the lower recent failure rate (from `job_attempts`),
  then the shorter queue.
- `timeout_s` = clamp(3 × p90, 300, 14400) once Phase 6 exists; until then, the workflow default or
  3600.

### Studio form and settings
- A user setting for affinity (my servers only / prefer my servers / any server), defaulting to
  "prefer" for users who own a server and "any" for everyone else.
- A "Run on: Auto / <server>" select on the studio form, which sets `pinned_backend_id`.
- A privacy notice when the job may run on someone else's server: "This may run on <owner>'s
  server. The server owner can see your prompt, images, and results." Show the actual server on the
  job afterwards.

### Outputs

Outputs are media and 3D only (decided). This replaces the original plan's `other` kind, which
would have been saved as a download. The server owner chooses the uploaded bytes, and may not be
the person viewing them, so the allowlist is enforced on the file's contents, not the agent's
labels.

**Upload side (`JobsController#outputs`):**
- Limits: 4 GB per file and 10 GB per job (environment settings). Stream to storage.
- Allowlist by kind:
  - image: png, jpeg, webp, gif (**not SVG**, which can contain scripts)
  - video: mp4, webm, mov
  - audio: wav, mp3, flac, ogg
  - 3d: glb, gltf, obj, ply, fbx
- Reject every other type with HTTP 415. The agent reports this as an `outputs` failure.
- Ignore the agent-supplied `mime`. Detect the type from the file's contents with Marcel, and
  reject the upload when it doesn't match the extension's kind (for example, a `.png` that is
  really HTML).
- Sanitize filenames: basename only, no control characters, no right-to-left override characters,
  and a length cap.

**Serving side:**
- Image, video, and audio are served inline with the detected type and
  `X-Content-Type-Options: nosniff`. That includes the public share controller, which should use
  the same helper as signed-in pages instead of its own `send_data`.
- 3D files are served as downloads until a viewer exists.
- Label every output with the server that produced it.

**Processing:** thumbnails and notification images (libvips in `NotificationImageShrinker`) only
touch detected png, jpeg, and webp files.

**Retention:** follow the existing history retention; add a "Don't keep my uploads" user setting
that deletes inputs when the job ends.

**Tests:** a `.png` that is really HTML is rejected; SVG, HTML, and other non-allowlisted uploads
get 415; allowlisted media is served with nosniff on both signed-in and public-share URLs;
filenames with path separators or right-to-left override characters are sanitized; only
allowlisted types reach the thumbnail code.

### Tests
Every scenario in test-plan §§7–11 and §16: concurrent dispatch (two threads, one wins), ack
timeout, each rejection reason, each failure branch, OOM re-routing to a larger-VRAM backend,
cancel in each state with the timeout fallback, lease expiry with the retry limit, reconciliation
cancel and requeue, buffered terminal events completing jobs, and output serving headers.

---

## Phase 6 — Performance and predictions (§7, §8)

### Tables
`perf_samples`, `perf_stats` (decayed regression sums), `backend_speeds`, `transfer_stats`,
`prediction_logs`, per §7's data model.

### Services
- **`Perf::Recorder`:** on `job.completed`, write a sample from the agent's `timings` plus
  `dispatch_ms`, then update `PerfStat` in O(1): decay by λ = 0.97, add with weight `w`. Weights:
  0.25 when `cached_ratio > 0.5`; 0.1 for outliers (more than 5× or less than 0.2× the prediction
  when n ≥ 5).
- **`Perf::Model`:** solve for `a` and `b` (clamped ≥ 0), with the proportional fallback when
  n < 3 or there's no spread in work units. p90 = p50 + 1.28 × √sres2.
- **Warm/cold:** warm when the previous Comfier job on this backend used the same `model_set_hash`,
  finished within `WARM_WINDOW_S`, and no status in the gap showed `foreign_running > 0`. Track that
  as a Redis flag per backend, cleared when a Comfier job starts.
- **`Perf::SpeedIndex`:** hourly job; new backends inherit the index of another backend with the
  same `gpu_name`.
- **`Perf::Predictor`:** the five-step fallback chain with confidence levels and a source number;
  `predicted_total = dispatch + inputs + execute + upload`.
- **`Agent::Timeline`:** recompute per backend (debounced to once a second) on progress, status,
  enqueue, dequeue, or completion:
  - the current job's remaining time blends predicted and progress-based estimates, weighted by
    progress;
  - `busy_local` adds the EWMA of past local-use durations and marks the estimate uncertain;
  - warmness is chained by `model_set_hash` in queue order;
  - `waiting_models` jobs start at max(previous end, download ETA) and don't delay the jobs behind
    them.

  Writes `predicted_start_at`, `predicted_end_at`, and `prediction_confidence`, and broadcasts.

### Routing and rebalancing
- Replace queue-length scoring with predicted finish time (§6 "Score").
- `RebalanceJob` every `REBALANCE_INTERVAL_S`, and when a backend comes online or a job finishes far
  from its prediction: move a job only when the gain is more than 25% and more than 30s, `moves < 3`,
  the job isn't pinned, affinity allows it, and it isn't a `waiting_models` job whose downloads are
  more than 50% done.

### UI
- Studio form, before submit: "Estimated: about 2 min on studio-4090, starts in about 5 min
  (3 jobs ahead)", computed by a small JSON endpoint called by a Stimulus controller when the form
  changes.
- Job card: time left, queue position, expected start.
- Confidence wording: high "about 2 min", medium "about 2–3 min", low "probably a few minutes (first
  run on this server)".
- The server page gets a performance table per job type: samples, p50 and p90 per work unit, warm
  vs cold, failure rate, prediction error.

### Accuracy and maintenance
- `PredictionLog` on every completion. The admin performance page shows median absolute percentage
  error per backend and per job type over 7 and 30 days.
- Keep samples for 90 days. A nightly job rebuilds `PerfStat` from samples.

### Tests
Every scenario in test-plan §§13–15: regression recovers synthetic `a` and `b`, decay favours
recent samples, the proportional fallback, outlier and cached weights, warm/cold including foreign
work, the speed index and GPU inheritance, each fallback step's confidence, the timeline cases, and
the rebalancing thresholds.

---

## Phase 7 — Load history, charts, admin overview (§9)

- `LoadMinute.record!`: add status-interval seconds into `backend_load_minutes` (online, busy,
  busy_local, queue_len_max, jobs_completed) with an upsert per `(backend_id, minute)`.
- A nightly rollup into `backend_load_hours`. Keep minutes for 30 days and hours for 1 year.
- **Charts (decided: a JavaScript library): Chart.js**, pinned through importmap
  (`bin/importmap pin chart.js`), which also pulls in its one dependency. One Stimulus
  `chart_controller` reads a JSON series from a `data-` attribute and draws a line or bar chart.
  JSON endpoints under the server page supply the data, so charts can refresh without reloading the
  page.
- Styling follows `ui.mdc`: a neutral grey series by default, color only where it means something
  (for example, red for failures), dark-theme grid colors read from CSS variables, 12px axis
  labels, and no animation.
- Charts on the server page: utilization per hour or day, jobs per day, and average execution time
  per job type. An admin overview: all servers, total queue, jobs per hour, prediction accuracy,
  high failure rates, and flapping connections.
- A system test that loads the server page and checks each chart canvas renders with data.
- Tests: minute accumulation, the rollup, retention, and the utilization calculation.

---

## Phase 8 — Legacy migration (§11)

- Put legacy and agent backends behind one `Backends::Runner` interface (`submit`, `cancel`,
  `inventory`, `download`), so `SubmitGenerationJob`, `GenerationCanceller`, and model downloads
  don't branch on `connection_kind`.
- Legacy server pages get a "Switch to the agent" prompt that issues a key and converts the server
  in place, keeping its history.
- Remove the downloader-node download path once no legacy backends need it (a separate PR).

---

## Test harness improvements (all phases)

- **A real socket test:** boot the Rack app under Puma in the test process on a random port, and
  drive it with a Faye WebSocket client (`Faye::WebSocket::Client`) wrapped in a
  `FakeAgent` class. Cover a 401 without upgrading, the hello timeout, `4426`, `4409` replacement,
  `1009`, the rate limit, and `4401` on revoke. The current tests call `MessageHandler` directly and
  skip the socket layer.
- `FakeAgent` scripts: hello, inventory, status, request, accept or reject, progress, fetch inputs,
  upload outputs, complete or fail with timings, disconnect and reconnect with `active_jobs` and
  buffered events, `busy_local`, and download responses.
- Every outbound message in every test is checked against the schema (a helper wrapping
  `FakeSocket#send`).

---

## Decisions

1. **Linking web and Sidekiq (Phase 0.1):** Redis presence keys plus pub/sub commands.
2. **Charts (Phase 7):** Chart.js through importmap.
3. **Outputs (Phase 5):** image, audio, video, and 3D only. Other types (SVG included) are rejected
   at upload after checking the file's contents. No separate domain; the public share fix ships
   with Phase 5.
4. **Sharing (Phase 1):** individual users only.
