# Custom generation backends

This document maps the parts of Palmier Pro that matter when replacing the hosted
image, video, and audio generation backend. It recommends the smallest design that
can grow without turning every upstream sync into a provider-integration rewrite.

The scope is media generation. The in-app editing agent is separate: it already
routes direct API-key and hosted chat traffic through `AgentClient` implementations
in `Sources/PalmierPro/Agent/Clients` and `AgentService.selectClient`.

## Recommendation

Treat the app as having two generation routes:

- `palmier-hosted`: the existing Clerk, Convex, storage, subscription, and credits path.
- `custom-gateway`: one user-configured HTTP service that can route to any number of
  image, video, and audio providers.

Do not add a Swift implementation for every upstream model vendor. Normalize those
vendors behind the gateway and keep the app contract stable. Inside the fork, put
the custom path in new files and connect it to the existing generation pipeline at
four narrow seams:

1. catalog loading;
2. access checks;
3. reference delivery and job execution;
4. pending-job recovery.

Start with image generation. Add video only after one image request works from both
the generation panel and the Agent/MCP tool path. Add audio after video recovery is
proven. This keeps every phase usable end to end.

## Local ComfyUI target

The first self-hosted gateway implementation targets ComfyUI while preserving the
existing Together-compatible app contract. Palmier Pro must not submit workflow
graphs or depend on ComfyUI node IDs. The gateway owns workflow templates, parameter
injection, ComfyUI queue execution, output collection, and provider-specific errors.

```text
Palmier Pro
  |  POST /v1/images/generations
  |  POST /v1/audio/speech
  |  POST /v2/videos
  |  GET  /v2/videos/{id}
  v
ComfyUI gateway
  |  select workflow by stable model ID
  |  inject validated request values
  |  submit /prompt and inspect queue/history/output
  v
Local ComfyUI
```

The initial local model set is:

| Media | Stable model ID | Workflow | Role |
| --- | --- | --- | --- |
| Image | `local/z-image-turbo` | Z-Image Turbo text-to-image | Fast default image generation |
| Image | `local/flux-2-dev` | FLUX.2 Dev text-to-image | Optional higher-cost local image generation |
| Video | `local/ltx-2.5-distilled` | LTX 2.5 distilled text-to-video or image-to-video | Local ten-second video generation |
| Audio | `local/kokoro-82m` | Kokoro 82M text-to-speech | Local configured-voice speech generation |

The gateway may later expose explicit cloud-backed model IDs, such as a Together
image model, through the same endpoint shapes. It must never silently fall back from
a selected local model to a billable provider or from one model to another. An
unavailable model fails with its requested stable ID, and completed generation
metadata preserves the actual model and backend used.

The image catalog must grow from the current single `custom/image/default` entry to
multiple selectable stable model entries. Model selection belongs to the shared
catalog and submission path so the panel and Agent/MCP tools expose the same choices.
The request `model` value selects the gateway workflow; separate per-model endpoints
or Swift vendor clients are not required.

Z-Image Turbo is the first implementation slice. It remains text-to-image only and
supports the five aspect ratios already accepted by the custom image contract. The
gateway waits for the ComfyUI image result and returns the existing OpenAI-compatible
`data` array with URL or base64 outputs. Multiple requested images are one coherent
request, and partial output is a failure rather than success with fewer images.

Reference-image generation remains disabled until the shared catalog, validation,
gateway request, UI, Agent/MCP schema, persistence, and undo-neutral generation
lifecycle support the same explicit contract. FLUX.2 capability alone is not a
reason to accept and then drop reference inputs.

LTX 2.5 maps Palmier's ten-second video request to 241 frames at 24 fps. Its input
dimensions must be divisible by 32, so the workflow may render 1376x768 and
center-crop to the requested 1366x768 output. A starting frame selects the
image-to-video workflow; otherwise the gateway selects text-to-video. The first
contract keeps `generate_audio` disabled and strips generated audio if the selected
workflow cannot avoid producing it.

The reference development machine currently runs ComfyUI Desktop 0.34.2 with
PyTorch 2.10 on Apple MPS. The official Z-Image Turbo BF16 diffusion model, Qwen 3 4B
text encoder, VAE, and workflow template have been discovered locally. These facts
are verification inputs, not hardcoded product paths or minimum requirements.

## Implementation status

Status as of September 1, 2026 on `fork/custom-providers`:

- Phase 1 text-to-image is implemented. The selected route, gateway URL, and remote
  model ID are persisted in settings; the API key is stored in Keychain.
- The custom route loads a bundled image-only catalog, bypasses Palmier account and
  credit requirements, and remains available in a signed-out or unconfigured build.
- `GenerationService` routes custom image requests through the gateway client and
  reuses the existing placeholder, project-package commit, and media finalization
  lifecycle.
- The image contract sends `POST /v1/images/generations` and accepts URL or base64
  results. A base URL ending in `/v1` is not given a duplicate version component.
- The speech contract sends `POST /v1/audio/speech`, requests MP3 output, and
  preserves the actual supported content type and extension returned by the gateway.
- `GenerationInput` persists `generationBackendID` and the resolved remote model ID,
  so completed assets retain the execution identity rather than depending on current
  settings.
- Configuration errors and gateway failures reach visible generation failure state.

Verified so far:

- focused custom-generation tests pass for catalog loading, access, endpoint
  resolution, request encoding, response decoding, aspect-ratio dimensions, MCP
  schema, and persisted routing metadata;
- a mock gateway generated an asset that remained usable after saving and reopening
  the project;
- the user verified a real Together serverless request with
  `black-forest-labs/FLUX.1-schnell` and the generated asset completed successfully;
- new configurations default to the current serverless image model
  `black-forest-labs/FLUX.2-dev`;
- the repository MCP client generated a Together image, polled it to completion,
  verified its requested 16:9 pixel dimensions, and read the asset back through
  `inspect_media`;
- a separate Codex task discovered and used the Palmier MCP tools to complete the
  same 16:9 generation and read-back workflow;
- the packaged app contains the custom catalog and passes signature verification.
- custom video generation completed through the panel and MCP with persisted backend,
  remote-model, and provider-job provenance visible through `inspect_media`.

Deliberately outside the completed Phase 1 scope:

- reference-image generation remains unsupported until a shared upload or inline
  reference contract is defined;
- remote cancellation is not promised because a provider may continue work after a
  client disconnects or abandons a request;
- generic project close, Save As, and teardown coordination remain upstream editor
  lifecycle responsibilities rather than custom-provider acceptance gates.

## Current structure

The relevant flow is:

```text
Generation panel                    Agent/MCP tools
GenerationView+Submit               ToolExecutor+Generate
          |                                  |
          +---------- Submission types -----+
                     |  ImageGenerationSubmission
                     |  VideoGenerationSubmission
                     |  AudioGenerationSubmission
                     v
               GenerationService
                |      |      |
          placeholders refs   job lifecycle
                |      |      |
                |      |      +--> GenerationBackend --> Convex
                |      +---------> BackendStorage ------> hosted upload
                +----------------> download/finalize ---> project package
```

### Ownership map

| Area | Current owner | Why it matters |
| --- | --- | --- |
| UI intent | `Generation/UI/GenerationView+Submit.swift` | Builds the same submission types used by tools. Provider logic does not belong here. |
| Agent/MCP intent | `Agent/Tools/ToolExecutor+Generate.swift` | Validates tool arguments, applies the shared hosted-or-custom access policy, then calls the shared submission types. |
| Request assembly | `Generation/Submission/*GenerationSubmission.swift` | Converts user-facing model settings and references into `BackendGenerationParams`. This should remain shared. |
| Model capabilities | `Generation/Catalog/ModelCatalog.swift` and the four model config files | The UI and tools validate against this catalog. Hosted mode uses the Convex `models:list` subscription; custom mode loads the bundled custom catalog. |
| Placeholder and result lifecycle | `Generation/GenerationService.swift` | Creates media placeholders, prepares references, persists job metadata, monitors jobs, downloads results, finalizes assets, and resumes work after reopening. This must remain the lifecycle owner. |
| Generation transport | `Generation/GenerationBackend.swift` and `Generation/CustomBackend/CustomGenerationRunner.swift` | Convex remains the hosted transport; the custom route is isolated in the gateway runner. |
| Hosted uploads | `Backend/BackendStorage.swift` | Requests a Convex upload ticket, uploads a file, and commits it to hosted storage. |
| Persistence | `Models/MediaManifest.swift` | `GenerationInput` stores the model, inputs, `backendJobId`, output indexes, and result URLs in the project. |
| Package commit | `GenerationService.downloadAndFinalize` and `EditorViewModel.commitStagedProjectMedia` | Installs completed media and runs the normal import/finalization path. Custom results must use this path too. |
| Startup recovery | `Project/VideoProject.swift` -> `GenerationService.resumePendingGenerations` | Groups placeholders by hosted job ID and reconnects the Convex subscription. |
| Access policy | `Generation/GenerationAccess.swift` | Returns the shared hosted-or-custom access decision used by the panel and Agent/MCP entry points. |

### Current invariants to preserve

- The panel and Agent/MCP entry points use the same submission and validation logic.
- One request creates its placeholders before background work begins.
- Every placeholder reaches ready, failed, refused, or cancelled state.
- Multi-output results map by `GenerationInput.outputIndex`.
- Result media is committed through the project package coordinator and then finalized
  through the existing media import path.
- A project checkpoint occurs after durable job metadata changes.
- Reopening a project can resume an accepted asynchronous job.
- Unsupported inputs fail explicitly. A custom route must not drop end frames,
  reference media, audio options, source trims, or model settings silently.
- Provider work, uploads, downloads, decoding, and filesystem access stay off the
  main actor. Only immutable results return to `GenerationService` for UI-owned
  state changes.

## Proposed design

### 1. One backend selection

Add a small settings owner in a new file, for example:

```text
Generation/CustomBackend/CustomGenerationConfiguration.swift
```

It owns:

- selected route: hosted or custom gateway;
- gateway base URL;
- remote model ID for the current image-only slice;
- API key reference, with the secret stored in Keychain;
- connection state and a user-visible configuration error.

Use an exclusive route for the first version: when custom is selected, all models
come from the custom catalog and all generation uses the gateway. Coexisting hosted
and custom catalogs add ID collision, billing, default-model, and routing policy
without helping the first end-to-end result.

Never infer a route from whether the Palmier backend happens to be configured.
Selection is explicit and persisted. Never send a custom request to the hosted path
as a fallback after an error.

### 2. One catalog source at a time

Add:

```text
Generation/CustomBackend/CustomGenerationCatalog.swift
Resources/GenerationCatalog/custom-generation-models.json
```

The bundled catalog decodes to the existing `CatalogEntry` type so the model config
and validation code remains unchanged. The current custom entry has:

- a stable app ID, currently `custom/image/default`;
- image, video, audio, or upscale capabilities expressed in the existing schema;
- a remote model ID supplied by settings and snapshotted into `GenerationInput` when
  the request runs.

Do not rely on a generic `/models` response for capabilities. A model list rarely
describes duration buckets, reference limits, first/last-frame support, source media,
voices, languages, or other validation rules Palmier needs before mutation. The
bundled catalog is the source of truth; gateway discovery may confirm availability
but must not invent permissive capabilities.

`ModelCatalog.configure()` gets one routing branch:

- hosted selected: run the existing Convex subscription unchanged;
- custom selected: load and apply the bundled custom entries.

Keep custom parsing and ID mapping out of `ModelCatalog.swift`. That file should only
choose a source and apply entries.

### 3. One access policy

Add a non-UI policy such as `GenerationAccess` with an outcome, not just a Boolean:

```swift
enum GenerationAccessResult: Equatable, Sendable {
    case allowed
    case refused(reason: String)
}
```

The policy evaluates the selected backend and model:

- hosted: preserve sign-in, credits, and paid-model checks;
- custom: require a valid configuration and an enabled catalog model; hosted credits
  and subscription tier do not apply.

Use it in the panel, audio panel, AI Edit surfaces, `ToolExecutor.canGenerate`, and
all three generate/upscale tool entry points. This removes the current repeated
`isSignedIn`/`hasCredits` decisions and keeps UI preview, tool discovery, and
execution consistent.

For custom models, cost UI should say external billing or omit an estimate. It must
not show zero Palmier credits as though the provider were free.

### 4. A gateway runner, not a provider framework

Add new files under:

```text
Generation/CustomBackend/
  CustomGenerationClient.swift
  CustomGenerationRunner.swift
  CustomGenerationContract.swift
```

`CustomGenerationClient` owns HTTP encoding and decoding. `CustomGenerationRunner`
owns synchronous versus asynchronous job behavior, polling, cancellation, and
provider error normalization. It runs outside the main actor and returns immutable,
sendable values.

A useful synchronous image result shape is:

```swift
struct CustomGenerationResult: Sendable {
    let stagedFiles: [URL]
}
```

Phase 2 adds a separate accepted-job receipt rather than making the synchronous
image result partially populated.

The runner does not create `MediaAsset`s, mutate the editor, write the live project
package, or implement timeline behavior. `GenerationService` remains authoritative
for placeholders, persisted metadata, result-to-output mapping, notifications, and
finalization.

The gateway contract can be OpenAI-compatible where a stable media endpoint exists,
but the app should depend on an explicit contract rather than a brand name:

```text
Image
POST /v1/images/generations or /v1/images/edits
-> URL results or base64 results

Video
POST /v2/videos
-> { id, status }
GET /v2/videos/{id}
-> { id, status, error?, outputs?: { video_url } }

Audio
POST /v1/audio/generations
-> audio bytes/base64, or the same accepted-job shape as video
```

Put vendor-specific field translation, authentication, webhooks, retries, and model
aliases behind this gateway. Palmier should only know its stable media contract.

### 5. Share reference preparation

`GenerationService.prepareReferences` currently combines two responsibilities:

1. local transforms such as trim extraction, audio extraction, and video preprocessing;
2. hosted upload and URL creation.

Keep local preparation shared. Add a delivery choice to the existing operation:

- hosted delivery uploads the prepared files and returns remote URLs;
- custom delivery passes the prepared local file URLs to the runner for multipart or
  inline transfer.

Do not implement a second trim, downscale, audio extraction, or reference-ordering
path in the custom runner. The `Submission` types must continue to build
`BackendGenerationParams` from the prepared locations so panel and tools remain
identical.

The prepared files have one scoped owner and are cleaned after success, failure, or
cancellation. File reads and encoding happen behind an explicit background boundary.

### 6. Route execution in `GenerationService`

After shared reference preparation and `buildParams`, add one route decision:

```text
hosted -> existing GenerationBackend.submit + Convex monitor
custom -> CustomGenerationRunner + shared finalization
```

The custom branch should feed staged result files into the same finalization operation
as hosted downloads. Extend that operation to accept a staged local file without
trying to download a `file:` URL. It still installs the file through
`commitStagedProjectMedia`; direct writes into a live `.palmier` package are not
allowed.

Keep the existing hosted `GenerationBackend` intact. Do not wrap every Convex call in
a new protocol merely to support one custom gateway. A protocol threaded through
upload, Combine subscriptions, activity, credits, and draft enhancement creates a
wide abstraction with little shared behavior and a large upstream conflict surface.

### 7. Persist the backend identity

Add an optional stable backend ID to `GenerationInput`, for example:

```swift
var generationBackendID: String?
```

Continue using `backendJobId` for the provider's durable job ID. Do not encode the
backend into the job ID with a string prefix: the two values have different meaning,
and prefixes make validation and future providers fragile.

On resume:

- `palmier-hosted` reconnects the existing Convex subscription;
- `custom-gateway` asks the runner to poll the stored job;
- an unavailable configured backend leaves the placeholder failed with an actionable
  message while retaining the job ID for retry;
- unknown backends never fall through to hosted execution.

Snapshot the remote model name or immutable model mapping needed to resume. Changing
the current catalog alias must not retarget an already accepted job.

### 8. Keep project activity separate initially

`ProjectActivityView` is backed by a hosted Convex project-activity subscription.
Custom jobs will already appear as media placeholders with generation state. Leave
the activity ledger hosted-only in the first version rather than building a second
history system. If a local history is later required, persist terminal receipts in
the project and make that its own feature.

## Why not copy the reference fork exactly?

[`protoLabsAI/protoDirector`](https://github.com/protoLabsAI/protoDirector) proves
that a thin gateway runner can work and that concentrating fork-specific code reduces
merge conflicts. Its useful patterns are:

- gateway logic lives in new files;
- the existing placeholder and finalization pipeline is reused;
- image results support both URL and base64 responses;
- asynchronous video IDs are persisted and resumed;
- a bundled capability catalog drives the existing UI;
- unsupported gateway inputs are rejected rather than ignored.

This design keeps those patterns but tightens several boundaries for this checkout:

- local reference preprocessing remains shared instead of being bypassed;
- backend identity is a persisted field instead of a job-ID prefix;
- file I/O and image/audio encoding must not run on the main actor;
- access checks become one policy rather than scattered gateway exceptions;
- custom routing is an explicit selection, not an inference from missing hosted
  configuration.

The reference fork's own design notes are useful context:

- [AI architecture](https://github.com/protoLabsAI/protoDirector/blob/main/docs/fork/AI_ARCHITECTURE.md)
- [Generation gateway plan](https://github.com/protoLabsAI/protoDirector/blob/main/docs/fork/GENERATION_GATEWAY_PLAN.md)
- [Gateway contract](https://github.com/protoLabsAI/protoDirector/blob/main/docs/fork/GATEWAY_CONTRACT.md)

## Delivery plan

### Phase 1: text-to-image — implemented

- [x] Add custom configuration, editable model ID, and Keychain storage.
- [x] Load a bundled image-only catalog when custom is selected.
- [x] Centralize access checks across the panel, tools, and related generation
  surfaces.
- [x] Implement text-to-image with URL and base64 responses.
- [x] Verify signed-out panel generation with a mock gateway and Together.
- [x] Verify project save, reopen, and use of a completed generated asset.
- [x] Verify `generate_image` through MCP, including 16:9 output dimensions, and
  independently read the asset back.
- [x] Verify the same workflow from a separate Codex task using Palmier's MCP server.

Reference-image edits are deferred. They require shared local preprocessing and a
defined upload/inline gateway contract; Phase 1 does not silently drop them.

Acceptance: a fresh signed-out app can select the custom backend, generate an image,
save the project, reopen it, and use the generated asset without Palmier credentials.

The panel and MCP paths meet this acceptance criterion. Phase 1 is complete.

### Phase 2: asynchronous video — complete

Together's current [video generation API](https://docs.together.ai/docs/inference/videos/overview)
fits the required lifecycle: create with `POST /v2/videos`, retrieve with
`GET /v2/videos/{id}`, and download the completed `outputs.video_url`.
Dedicated-endpoint management is not part of this phase.

Phase 2 implements:

1. **Per-media remote model configuration.** Explicit image and video model IDs
   replace the single generic setting. The selected video model is snapshotted into
   `GenerationInput.remoteModel`, so changing settings later does not retarget an
   accepted job.
2. **One conservative video catalog entry.** The catalog describes only the durations,
   resolutions, aspect ratios, audio behavior, and input modes actually supported by
   the first Together model. It exposes text-to-video and one starting frame, but no
   end frame or general image, video, or audio references.
3. **Accepted-job contracts.** Create and retrieve request/response types
   plus an immutable receipt containing backend ID, remote model ID, and job ID.
   Normalize only `queued`, `in_progress`, `completed`, and `failed`; unknown states
   fail explicitly.
4. **Persist acceptance before polling.** The service immediately writes `generationBackendID`,
   `remoteModel`, and `backendJobId` to every placeholder and checkpoint the project.
   A crash after acceptance must leave enough state to resume the same remote job.
5. **Poll outside the main actor.** The runner uses a bounded cadence, honors local cancellation,
   applies a finite request timeout, and surfaces provider errors. A local timeout or missing
   credentials must preserve the remote job ID for retry instead of submitting again.
   Cancellation stops local polling and commits; it does not promise cancellation of
   provider work.
6. **Route startup recovery by persisted backend.** Hosted IDs continue through
   Convex; custom IDs retrieve the stored remote job. Unknown backends fail visibly
   and never fall through to hosted. Deduplicate concurrent resume attempts for the
   same job.
7. **Reuse exact finalization.** Completed video downloads use a unique staged
   location off the main actor, validate its HTTP response and media type, and install
   it through `commitStagedProjectMedia`. Repeated terminal polling must not install a
   second asset.
8. **One image-to-video mode.** A prepared starting frame is sent inline through
   Together's top-level `frame_images` contract. End frames and other reference
   combinations remain unsupported.

Required automated coverage:

- create and retrieve encoding/decoding, including every terminal state and malformed
  or unknown responses;
- acceptance metadata is checkpointed before the first poll;
- cancellation before submit, while polling, and after completion before commit;
- timeout and transient retrieval failure preserve the job for retry;
- reopen resumes without duplicate submission or duplicate finalization;
- changed route, credentials, or model settings cannot retarget a persisted job;
- result download and package installation failures remain observable and retryable;
- MCP discovery, text-to-video execution, read-back, failure, and reopen recovery.

Acceptance: text-to-video and one supported image-to-video case complete; quitting
after acceptance and reopening resumes the same job and installs exactly one result.

Text-to-video, image-to-video, and MCP provenance read-back have been verified against
Together. Phase 2 is complete.

### Phase 3: audio — complete

- [x] Add one text-to-speech catalog entry using the existing audio submission path.
- [x] Add an independent audio model setting, defaulting to the current Together
  serverless `hexgrad/Kokoro-82M` model.
- [x] Make the ordered voice list configurable in settings; use the first configured
  voice as the default for both the panel and MCP.
- [x] Send the OpenAI-compatible `POST /v1/audio/speech` request with explicit model,
  input, voice, and response format.
- [x] Preserve the returned supported content type and file extension during staging
  and shared project-package finalization.
- [x] Reject source media, references, lyrics, music controls, duration, and other
  unsupported inputs instead of silently dropping them.
- [x] Route the panel and `generate_audio` through the same catalog validation,
  submission, backend selection, and finalization path.

The first slice is synchronous, so it does not reuse the video accepted-job contract.
Source-audio/video transforms remain deferred until a custom model and gateway contract
require them.

Acceptance: panel and `generate_audio` use the same model validation and produce a
ready audio asset with waveform/finalization behavior matching hosted results.

The panel and MCP paths have been verified against Together. Phase 3 is complete.

### Phase 4: optional provider management

Only add multiple in-app gateway profiles if there is a demonstrated need. Until
then, provider/model routing belongs in the gateway. Multiple profiles require an
explicit per-job profile ID, independent credentials, catalog namespacing, resume
behavior when a profile is deleted, and UI for choosing the route.

## Verification matrix

Automated coverage should include:

- catalog decode and model-ID mapping;
- access results for hosted/custom, configured/missing, credits/no credits, and paid
  model rules;
- request encoding and URL/base64 response decoding;
- reference ordering and unsupported-capability rejection;
- zero outputs, fewer outputs than placeholders, malformed URLs, non-HTTP responses,
  provider failures, cancellation, and timeout;
- persisted backend/job metadata and deterministic resume;
- local staged result installation through the package coordinator;
- no-op/retry behavior without duplicate assets or duplicate jobs;
- MCP schema/discovery plus end-to-end generate, poll/read-back, failure, and resume.

Run focused tests while iterating, then `swift build` and `swift test`. Each new UI
surface still needs manual verification for selection, disabled states, failure copy,
and dismissal during submission. Generic close, Save As, quit, and package-mutation
coordination follow the upstream editor lifecycle contract.

## Upstream workflow

Keep `main` as an exact mirror of upstream. Never merge fork work into it.

Recommended branches:

```text
main                    mirror of palmier-io/palmier-pro main
fork/custom-providers   the long-lived product branch
work/<topic>            short-lived branches based on fork/custom-providers
```

Configure the remotes once:

```bash
git remote add upstream https://github.com/palmier-io/palmier-pro.git
git fetch upstream
```

Sync `main` using fast-forward only:

```bash
git switch main
git fetch upstream
git merge --ff-only upstream/main
git push origin main
```

Then replay the fork instead of merging upstream into it:

```bash
git switch fork/custom-providers
git rebase main
git push --force-with-lease origin fork/custom-providers
```

Useful repository setting:

```bash
git config rerere.enabled true
```

Keep the fork changes as a small ordered commit stack so recurring conflicts are easy
to recognize:

1. custom configuration and catalog;
2. centralized access policy;
3. `GenerationService` routing seams;
4. image client and tests;
5. video client, persistence, recovery, and tests;
6. audio client and tests;
7. settings UI and localization.

Prefer new fork-owned files. When an upstream file needs a seam, keep the change to a
small call or route selection and put the implementation elsewhere. Avoid reformatting
or unrelated cleanup in those files. After each upstream rebase, inspect the complete
generation call path again: upstream changes to submission validation, reference
preprocessing, finalization, persistence, or recovery can invalidate a conflict-free
rebase semantically.

## Resolved decisions and next choice

Phase 1 resolved the original decisions:

1. the gateway uses a user-editable base URL and bearer authentication;
2. image generation uses the OpenAI-compatible `/v1/images/generations` shape;
3. the first verified model is `black-forest-labs/FLUX.1-schnell`;
4. custom selection exclusively replaces hosted generation and never falls back;
5. URL, remote model ID, and API key are user-configurable, with the key in Keychain.

Phase 2 uses `minimax/hailuo-02` from Together's current
[serverless catalog](https://docs.together.ai/docs/serverless/models). The bundled
catalog exposes its verified 10-second, 768p, 16:9 text-to-video and starting-frame
image-to-video modes without audio. Live panel, quit/reopen, and MCP verification are
still required before marking the acceptance criteria complete.
