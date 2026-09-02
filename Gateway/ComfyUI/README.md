# Palmier ComfyUI gateway

This local gateway advertises Palmier Pro model capabilities and translates the
custom generation contract into ComfyUI workflows. Model descriptors and workflow
JSON are loaded from disk for each catalog and generation request, so they can be
changed without rebuilding or restarting Palmier Pro or the gateway.

Requirements:

- Node.js 20 or newer;
- ComfyUI reachable at `http://127.0.0.1:8188` by default;
- `z_image_turbo_bf16.safetensors` in ComfyUI `diffusion_models`;
- `qwen_3_4b.safetensors` in ComfyUI `text_encoders`;
- `ae.safetensors` in ComfyUI `vae`.

Start the gateway with a local bearer token:

```bash
cd Gateway/ComfyUI
PALMIER_GATEWAY_API_KEY='replace-with-a-local-secret' npm start
```

Then configure Palmier Pro's custom gateway:

- Gateway URL: `http://127.0.0.1:8190`
- API key: the value of `PALMIER_GATEWAY_API_KEY`

Palmier loads its custom model picker from the authenticated
`GET /v1/palmier/models` endpoint. Use the Refresh button in Settings > Models after
editing gateway model descriptors.

## Model descriptors

The gateway reads files ending in `.model.json` from `models/`. Each descriptor owns:

- the catalog entry Palmier displays and validates;
- the ComfyUI workflow file;
- supported aspect ratios and their output dimensions;
- bindings from Palmier request values to ComfyUI node inputs.

`models/z-image-turbo.model.json` is the reference descriptor. To experiment with a
different image workflow, add another `.model.json` file with a unique stable model
ID and point it to an API-format ComfyUI workflow. The descriptor and workflow are
re-read on the next refresh or generation request. Invalid descriptors fail the
catalog request; unsupported model IDs fail rather than falling back.

The descriptor executor currently supports image workflows. Video and audio model
entries must not be advertised until their gateway executors are implemented; once
the LTX video executor exists, its workflow variants can use the same hot-loaded
descriptor model.

The gateway binds to localhost unless `PALMIER_GATEWAY_HOST` is set. Optional
configuration:

- `PALMIER_GATEWAY_PORT`, default `8190`;
- `PALMIER_COMFY_URL`, default `http://127.0.0.1:8188`;
- `PALMIER_COMFY_TIMEOUT_MS`, default `900000`.
- `PALMIER_GATEWAY_MODELS_DIR`, default `Gateway/ComfyUI/models`.

Run the gateway tests with `npm test`.
