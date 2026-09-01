# Palmier ComfyUI gateway

This local gateway preserves Palmier Pro's custom image endpoint while executing the
official Z-Image Turbo workflow in ComfyUI.

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
- Image Model ID: `local/z-image-turbo`
- API key: the value of `PALMIER_GATEWAY_API_KEY`

The gateway binds to localhost unless `PALMIER_GATEWAY_HOST` is set. Optional
configuration:

- `PALMIER_GATEWAY_PORT`, default `8190`;
- `PALMIER_COMFY_URL`, default `http://127.0.0.1:8188`;
- `PALMIER_COMFY_TIMEOUT_MS`, default `900000`.

Run the gateway tests with `npm test`.
