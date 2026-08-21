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

## Implementation status

Status as of August 21, 2026 on `fork/custom-providers`:

- Phase 1 text-to-image is implemented. The selected route, gateway URL, and remote
  model ID are persisted in settings; the API key is stored in Keychain.
- The custom route loads a bundled image-only catalog, bypasses Palmier account and
  credit requirements, and remains available in a signed-out or unconfigured build.
- `GenerationService` routes custom image requests through the gateway client and
  reuses the existing placeholder, project-package commit, and media finalization
  lifecycle.
- The image contract sends `POST /v1/images/generations` and accepts URL or base64
  results. A base URL ending in `/v1` is not given a duplicate version component.
- `GenerationInput` persists `generationBackendID` and the resolved remote model ID,
  so completed assets retain the execution identity rather than depending on current
  settings.
- Configuration errors and gateway failures reach visible generation failure state.

Verified so far:

- focused custom-generation tests pass for catalog loading, access, endpoint
  resolution, request encoding, response decoding, and persisted routing metadata;
- a mock gateway generated an asset that remained usable after saving and reopening
  the project;
- the user verified a real Together serverless request with
  `black-forest-labs/FLUX.1-schnell` and the generated asset completed successfully;
- the packaged app contains the custom catalog and passes signature verification.

Still open from the broader Phase 1 design:

- run `generate_image` through the MCP boundary against the real gateway and read the
  resulting asset back independently;
- reference-image generation remains deliberately unsupported;
- cancellation, project close, Save As, and gateway failure behavior still need the
  complete manual lifecycle matrix.

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
| Agent/MCP intent | `Agent/Tools/ToolExecutor+Generate.swift` | Validates tool arguments, then calls the shared submission types. It currently hard-gates on Palmier sign-in and credits. |
| Request assembly | `Generation/Submission/*GenerationSubmission.swift` | Converts user-facing model settings and references into `BackendGenerationParams`. This should remain shared. |
| Model capabilities | `Generation/Catalog/ModelCatalog.swift` and the four model config files | The UI and tools validate against this catalog. It is currently populated only by the Convex `models:list` subscription. |
| Placeholder and result lifecycle | `Generation/GenerationService.swift` | Creates media placeholders, prepares references, persists job metadata, monitors jobs, downloads results, finalizes assets, and resumes work after reopening. This must remain the lifecycle owner. |
| Hosted RPC | `Generation/GenerationBackend.swift` | Concrete Convex submit, subscription, activity, and draft-enhancement calls. There is no transport abstraction today. |
| Hosted uploads | `Backend/BackendStorage.swift` | Requests a Convex upload ticket, uploads a file, and commits it to hosted storage. |
| Persistence | `Models/MediaManifest.swift` | `GenerationInput` stores the model, inputs, `backendJobId`, output indexes, and result URLs in the project. |
| Package commit | `GenerationService.downloadAndFinalize` and `EditorViewModel.commitStagedProjectMedia` | Installs completed media and runs the normal import/finalization path. Custom results must use this path too. |
| Startup recovery | `Project/VideoProject.swift` -> `GenerationService.resumePendingGenerations` | Groups placeholders by hosted job ID and reconnects the Convex subscription. |
| Access policy | `AccountService`, `ToolExecutor`, `AIEditMenu`, generation UI, audio panel, and editor helpers | Hosted account rules are currently repeated at several call sites. A custom backend will remain invisible until these use one shared decision. |

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
POST /v1/videos
-> { id, status }
GET /v1/videos/{id}
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
- [ ] Verify `generate_image` through MCP and independently read the asset back.
- [ ] Complete the manual cancellation, close, Save As, and failure matrix.

Reference-image edits are deferred. They require shared local preprocessing and a
defined upload/inline gateway contract; Phase 1 does not silently drop them.

Acceptance: a fresh signed-out app can select the custom backend, generate an image,
save the project, reopen it, and use the generated asset without Palmier credentials.

The panel path meets this acceptance criterion. MCP verification remains the entrance
gate for Phase 2 implementation.

### Phase 2: asynchronous video — next

Together's current [video generation API](https://docs.together.ai/docs/inference/videos/overview)
fits the required lifecycle: create with `POST /v1/videos`, retrieve with
`GET /v1/videos/{id}`, and download the completed `outputs.video_url`.
Dedicated-endpoint management is not part of this phase.

Implement Phase 2 in this order:

1. **Close the image entrance gate.** Exercise `generate_image` through MCP against
   the configured gateway, read the completed media asset back, and verify a gateway
   refusal produces a terminal tool failure rather than a success-shaped receipt.
2. **Add per-media remote model configuration.** Replace the single generic model
   setting with explicit image and video model IDs. Snapshot the selected video model
   into `GenerationInput.remoteModel`; changing settings later must not retarget an
   accepted job.
3. **Add one conservative video catalog entry.** Describe only the durations,
   resolutions, aspect ratios, audio behavior, and input modes actually supported by
   the first Together model. Start with text-to-video; do not expose image or video
   references until their delivery contract is implemented.
4. **Define accepted-job contracts.** Add create and retrieve request/response types
   plus an immutable receipt containing backend ID, remote model ID, and job ID.
   Normalize only `queued`, `in_progress`, `completed`, and `failed`; unknown states
   fail explicitly.
5. **Persist acceptance before polling.** Immediately write `generationBackendID`,
   `remoteModel`, and `backendJobId` to every placeholder and checkpoint the project.
   A crash after acceptance must leave enough state to resume the same remote job.
6. **Poll outside the main actor.** Use a bounded cadence, honor cancellation, apply a
   finite request timeout, and surface provider errors. A local timeout or missing
   credentials must preserve the remote job ID for retry instead of submitting again.
7. **Route startup recovery by persisted backend.** Hosted IDs continue through
   Convex; custom IDs retrieve the stored remote job. Unknown backends fail visibly
   and never fall through to hosted. Deduplicate concurrent resume attempts for the
   same job.
8. **Reuse exact finalization.** Download the completed video to a unique staged
   location off the main actor, validate its HTTP response and media type, and install
   it through `commitStagedProjectMedia`. Repeated terminal polling must not install a
   second asset.
9. **Add the first image-to-video mode only after recovery passes.** Reuse existing
   image preprocessing, define how the prepared image reaches Together, and reject
   end-frame or reference combinations the selected model cannot honor.

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

### Phase 3: audio

- Add one audio category first, such as text-to-speech or music generation.
- Reuse the video accepted-job contract if the operation is asynchronous.
- Preserve actual content type and file extension.
- Add source-audio/video transforms only through the existing audio submission and
  preprocessing operations.

Acceptance: panel and `generate_audio` use the same model validation and produce a
ready audio asset with waveform/finalization behavior matching hosted results.

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

Run focused tests while iterating, then `swift build` and `swift test`. UI behavior
still needs manual verification for selection, disabled states, failure copy, Escape
or dismissal during submission, project close, Save As, quit, and reopen.

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

Before Phase 2 code begins, choose the first Together video model from the current
[serverless catalog](https://docs.together.ai/docs/serverless/models) and record its
exact text-to-video and image-to-video capability matrix in the bundled catalog.
`minimax/video-01-director` is the lowest-risk text-to-video starting point because
Together uses it in the official asynchronous polling example and lists a fixed
720p/5-second tier. Image-to-video can follow with a model whose keyframe behavior is
documented. This model choice is the only product decision needed; the lifecycle,
persistence, recovery, and finalization architecture is defined above.
