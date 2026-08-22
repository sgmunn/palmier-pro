# Custom image generation through MCP

This test controls a running Palmier Pro app through its local MCP server, submits
one custom-gateway image request, polls the placeholder, and reads the completed
image back through `inspect_media`.

The MCP client never reads the gateway API key. Palmier loads the key from Keychain
and makes the Together request itself.

This workflow was verified on August 21, 2026 with both the repository client and a
separate Codex task. Both produced a 16:9 asset and read it back through MCP.

## Prerequisites

1. Build and open the current Palmier Pro app.
2. Open or create a disposable project and leave that project frontmost.
3. In Settings > Models, select Custom Gateway and configure:
   - Gateway URL: `https://api.together.ai/v1`
   - Model ID: `black-forest-labs/FLUX.1-schnell`
   - API key: a saved Together key
4. In Settings > Agent, enable MCP Server. Palmier listens only on
   `http://127.0.0.1:19789/mcp`.

## Check the connection without generating

From the repository root, run:

```bash
node scripts/mcp/test-custom-image.mjs --check
```

This initializes an MCP session, discovers the required tools, binds to the
frontmost project, and confirms `custom/image/default` is available. It does not
make a billable generation request.

If more than one project is open, target one explicitly:

```bash
node scripts/mcp/test-custom-image.mjs --check --project-name "MCP Test"
```

or:

```bash
node scripts/mcp/test-custom-image.mjs --check --project-path "/absolute/path/MCP Test.palmier"
```

## Run the paid end-to-end test

```bash
node scripts/mcp/test-custom-image.mjs
```

The script shows the target project and asks before making one billable request.
It then:

1. calls `generate_image` with `custom/image/default`;
2. extracts the returned placeholder asset ID;
3. polls that ID with `get_media` until `generationStatus` disappears or fails;
4. calls `inspect_media` and requires an image response.

A successful run verifies that the returned pixel dimensions match the requested
aspect ratio and ends with output like:

```text
PASS: <media-ref> is 1024x576 and inspect_media read back image/jpeg through MCP.
```

Useful options:

```bash
node scripts/mcp/test-custom-image.mjs \
  --prompt "A locked-off wide shot of waves striking a black basalt coast" \
  --name "MCP Together verification" \
  --aspect-ratio "16:9"
```

Use `--yes` only in an intentional non-interactive run. It bypasses the billing
confirmation.

## Control Palmier from Codex

Register the same local server with the Codex CLI:

```bash
codex mcp add palmier-pro --url http://127.0.0.1:19789/mcp
```

Start a new Codex task after registering it, keep Palmier open, and ask:

```text
Use the palmier-pro MCP server. List the projects and image models, generate one
16:9 image in the frontmost project with the custom image model, poll get_media
until it is ready, then verify it with inspect_media. Do not use any other image
generation service.
```

The repository script is the reproducible acceptance test. Interactive Codex
control is useful for confirming that a normal external agent can perform the same
workflow.

## Troubleshooting

- `Cannot connect`: launch Palmier and enable Settings > Agent > MCP Server.
- `Editor not available`: open a project, or pass `--project-name` or
  `--project-path`.
- `Custom image model is unavailable`: select Custom Gateway and wait for the model
  catalog to finish loading.
- `Enter a gateway ...`: complete the URL, model ID, or API-key setting in Palmier.
- `project is not active`: bring the MCP session's project window to the front and
  retry.
- `Generation failed`: inspect the failed placeholder in Palmier or rerun
  `get_media` for its returned media reference to see the gateway error.
