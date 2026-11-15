# User API

In Comfier, open **Settings → API documentation** to read this guide or use **Copy for LLM** to
copy the complete Markdown for an AI assistant. Examples on that page use your installation's URL;
replace the placeholder token with your own when running them. The copied guide does not include your token.

The `/api/v1` JSON API lets scripts list workflows, submit generations, poll their status, cancel work,
and download results. It uses the same validation, queue, server permissions, and generation settings
as the web interface. The existing `/api/agent` endpoints are a separate API for generation servers.

## Authentication

Sign in to Comfier and open **Settings → API tokens**. Give a token a name and copy its value when
it is created; Comfier shows the full token only once and stores only its digest. Tokens begin with
`cmfu_`. Send the token on every API request, including output downloads:

```http
Authorization: Bearer cmfu_…
```

Delete a token from the same Settings page when it is no longer needed. Deletion immediately
invalidates the token and removes it from your list. Use HTTPS outside local
development. User tokens cannot authenticate generation servers, and server keys cannot authenticate
this API. Browser session cookies are not API authentication.

Tokens act as their owner. Even administrators can use this API to read, cancel, or download only
their own generations. Before using the API, accept the current Code of Conduct and privacy notice
in the web interface. If the notice changes, the API returns `403` until you accept the new version.

## Endpoints

All paths below are relative to your Comfier URL.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/workflows` | List enabled workflows and their supported inputs. |
| POST | `/api/v1/generations` | Submit a generation; returns `201` with its ID and a `Location` header. |
| GET | `/api/v1/generations` | List your generations, newest first. |
| GET | `/api/v1/generations/:id` | Get status, progress, parameters, errors, and output URLs. |
| POST | `/api/v1/generations/:id/cancel` | Request cancellation of a queued or running generation. |
| GET | `/api/v1/generations/:id/outputs/:output_id` | Download an output with Bearer authentication. |

Generation submission accepts JSON or multipart form data under a `generation` object. File uploads
use multipart form data. Submission returns immediately; poll the generation URL until `status` is
`succeeded` or `failed`. Cancellation uses the existing generation lifecycle and can finish asynchronously. A cancelled generation
finishes with `status: "failed"` and `cancelled: true`. Backend availability is checked by the
normal scheduler after submission; an accepted generation can subsequently fail if no server can run it.

## How to use the API

Use your Comfier URL in place of `https://comfier.example.com` and your personal token in place of
`YOUR_TOKEN`. The IDs below are examples; use the IDs returned by your requests.

### 1. Choose a workflow

List the available workflows. Choose one by its `id` and check its `inputs` to see which controls
it supports and which are required. A workflow determines what kind of output you create.

```bash
curl --fail-with-body 'https://comfier.example.com/api/v1/workflows' \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

### 2. Submit a generation

Send the workflow ID and supported inputs inside a `generation` object. For example, if workflow
`12` accepts a prompt and aspect ratio:

```bash
curl --fail-with-body 'https://comfier.example.com/api/v1/generations' \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: unique-request-001' \
  --data '{"generation":{"workflow_id":12,"prompt":"A lighthouse above a misty sea","aspect_ratio":"16:9"}}'
```

A successful submission returns `201` with a `generation` object. Save its `id`; the `Location`
header also identifies its status URL. Submission queues the work and returns before it finishes.

The optional `Idempotency-Key` prevents duplicate jobs when retrying a submission. Use a fresh key
for each new intended generation. Reuse the same key and identical request only when retrying that
submission, such as after a lost connection. See **Retrying submissions** below for details.

### 3. Check progress

Request the generation by its ID. For example, if submission returned `generation.id` of `42`:

```bash
curl --fail-with-body 'https://comfier.example.com/api/v1/generations/42' \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

Repeat this request every few seconds while `status` is `queued` or `running`. When it becomes
`succeeded`, the `outputs` array contains the available files. When it becomes `failed`, read
`error` for the reason and stop polling. A cancelled generation also finishes as `failed`, with
`cancelled` set to `true`; check that flag rather than the `error` text.

### 4. Download an output

Use an output's `download_url` from the generation response and send the same Bearer token.
For example, if that URL ends in `/generations/42/outputs/7`:

```bash
curl --fail-with-body 'https://comfier.example.com/api/v1/generations/42/outputs/7' \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  --output result.bin
```

Choose a local filename appropriate to the output's `filename` or `content_type`. Download each
entry in `outputs` if the generation produced multiple files. Output URLs require authentication;
sharing a download URL alone does not give someone access to the file.

### Use a reference image

For workflows with an image input, use multipart form data instead of JSON. Send the image as
`generation[input_image]` and the other inputs as `generation[field_name]`. For example, if workflow
`15` supports an image, prompt, and denoise:

```bash
curl --fail-with-body 'https://comfier.example.com/api/v1/generations' \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -F 'generation[workflow_id]=15' \
  -F 'generation[prompt]=A watercolor version of this scene' \
  -F 'generation[input_image]=@reference.png' \
  -F 'generation[denoise]=0.6'
```

Replace `reference.png` with your local image path. Let curl set the multipart content type so it
includes the correct boundary. Follow the same status and download steps as for a JSON submission.

### Cancel a generation

Send a POST to the generation's cancellation URL while it is queued or running:

```bash
curl --fail-with-body --request POST 'https://comfier.example.com/api/v1/generations/42/cancel' \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

Cancellation can take time. Keep checking the generation until it reaches a terminal status;
a cancelled generation then has `status: "failed"` and `cancelled: true`.
If it has already finished, cancellation returns `409 not_cancellable`.

## Generation inputs

`GET /api/v1/workflows` returns a `workflows` array. Each entry has `id`, `name`, `kind`,
`description`, and an `inputs` object keyed by the supported field names. For example:

```json
{
  "workflows": [{
    "id": 1,
    "name": "Watercolor",
    "kind": "image",
    "description": "Soft painted scenes",
    "inputs": {
      "prompt": {"type": "string", "required": true, "max_length": 10000},
      "aspect_ratio": {"type": "string", "required": false, "enum": ["1:1", "4:3", "3:4", "16:9", "9:16"]},
      "seed": {"type": "integer", "required": false, "minimum": 0, "maximum": 4294967295}
    }
  }]
}
```

A file input has `type: "file"`; numeric inputs describe their `minimum` and `maximum`.
Fields appear only when used by the workflow. `kind` is the type of output the workflow creates:
`image`, `video`, `audio`, or `model_3d` (a 3D model).

Only send controls supported by the chosen workflow. The workflow response describes those inputs;
`workflow_id` always selects the workflow, which determines the output kind. Raw workflow graphs,
server credentials, output attachments, status, and ownership cannot be supplied by clients.

| Field | Meaning |
| --- | --- |
| `workflow_id` | ID from the workflow list; required. |
| `prompt` | Prompt text; required when the workflow uses it, up to 10,000 characters. |
| `negative_prompt` | Optional things to avoid, up to 10,000 characters. |
| `input_image` | Multipart image file for workflows with an image input; required for those workflows. See **Reference images** below. |
| `seed` | Optional integer from 0 through 4294967295; omitted means random. |
| `aspect_ratio` | `1:1`, `4:3`, `3:4`, `16:9`, or `9:16`; defaults to your preferred shape. |
| `duration` | Duration in seconds, from 1 through 30. |
| `quality` | `fast`, `standard` (default), or `best`; scales the workflow's sampling steps. |
| `cfg_level` | `loose`, `balanced` (default), or `strict`; scales the workflow's prompt guidance. |
| `denoise` | Reference-image change strength from 0.1 through 1.0, default 0.6. |
| `lyrics` | Lyrics text; required when the workflow uses it, up to 10,000 characters. |
| `batch_size` | Number of outputs from 1 through 4, default 1. |

Width, height, frame count, sampling steps, and guidance are derived by the workflow from these
controls. The returned `parameters` object contains the resolved values. As in the web interface,
numeric controls are clamped to their supported ranges and unrecognized choice values fall back
to defaults. The API's `denoise` uses a fraction (for example `0.6`), rather than the web form's percentage.

### Reference images

Send `input_image` as a still image. PNG, JPEG, and WebP are the safe choices. Comfier stores the
upload as sent and does not check its type, convert it, or resize it; the generation server reads it
when the job runs. A file the server cannot read as an image is therefore accepted at submission
(`201`), and the generation then normally finishes with `status: "failed"` and a reason in `error`.

Comfier sets no upload size limit of its own. The installation's reverse proxy may reject large
request bodies, usually with `413`, before the request reaches the API. Keep reference images to a
few megabytes.

## Listing and polling

`GET /api/v1/generations?page=1&per_page=25` returns a `generations` array and
`pagination: {page, per_page, next_page}`. Pages start at 1; `per_page` defaults to 25 and is capped at 100.
A `null` `next_page` means there are no more results. Invalid or nonpositive pagination values return `400`.

Individual responses use a `generation` object. It includes the ID, workflow ID and name, kind,
status, prompt, negative prompt, resolved parameters, creation and completion timestamps, error,
a `cancelled` flag, and an `outputs` array. `kind` is `image`, `video`, `audio`, or `model_3d`.
`cancelled` is `true` only for a generation that was cancelled, and `false` otherwise. Each output
includes `id`, `filename`, `content_type`, `byte_size`, and `download_url`. Downloads require the same Bearer token; these URLs do not publish the output.

The coarse `status` is `queued`, `running`, `succeeded`, or `failed`. `progress` contains `phase`
and `fraction`. `fraction` is a number from `0` (not started) through `1` (complete), so multiply by
100 for a percentage; `phase` is a short label for the current step, or `null` when none is reported.
Some servers and phases report no progress, in which case `fraction` stays at `0` until the generation
finishes. Use `status`, not `fraction`, to decide when to stop polling. Poll every few seconds
until a terminal status is returned. Output URLs appear once files have been saved.

## Retrying submissions

The optional `Idempotency-Key` header accepts 1–255 bytes. Keys are scoped to the user,
so another token for the same user can safely retry a request. The server remembers the key and
request fingerprint, including uploaded file contents, filename, and content type. Receipts persist
even if a generation is deleted; retrying a deleted generation returns `409` rather than creating another job.

- A new key creates one generation and returns `201`.
- Repeating the same key and payload returns that generation's current state with `200` and
  `Idempotency-Replayed: true`; it does not enqueue another generation.
- Repeating the key with a different payload returns `409 idempotency_conflict`.

Keep the same key for retries of one request and generate a fresh key for each new intended job.
Without a key, each successful POST creates a new generation.

## Errors

JSON errors use this envelope:

```json
{"error":{"code":"validation_failed","message":"Generation is invalid.","details":{}}}
```

The `details` member, when present, supplies field-specific validation information. Clients should
use the HTTP status and error code rather than matching human-readable message text.

| HTTP status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | Malformed request or invalid request structure. |
| 401 | `invalid_token` | Missing, invalid, or deleted personal token. |
| 403 | `privacy_acceptance_required` | Accept the current notice in the web interface. |
| 404 | `not_found` | Resource does not exist or does not belong to this user. |
| 409 | `idempotency_conflict` | Idempotency key was already used for a different request. |
| 409 | `not_cancellable` | Generation is no longer queued or running. |
| 422 | `validation_failed` | Generation failed the normal input/workflow validation. |
