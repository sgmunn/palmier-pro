import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { ModelRegistry } from "../src/model-registry.mjs";

const registry = new ModelRegistry({
  modelsDirectoryURL: new URL("../models/", import.meta.url),
});

test("configures the official Z-Image Turbo graph for a Palmier request", async () => {
  const prepared = await registry.prepareImage({
    model: "local/z-image-turbo",
    prompt: "  A quiet harbor at sunrise  ",
    n: 3,
    aspect_ratio: "16:9",
  });
  const workflow = prepared.workflow;

  assert.equal(prepared.modelID, "local/z-image-turbo");
  assert.equal(prepared.count, 3);
  assert.equal(workflow["27"].inputs.text, "A quiet harbor at sunrise");
  assert.equal(workflow["13"].inputs.width, 1024);
  assert.equal(workflow["13"].inputs.height, 576);
  assert.equal(workflow["13"].inputs.batch_size, 3);
  assert.equal(workflow["3"].inputs.steps, 8);
  assert.equal(workflow["28"].inputs.unet_name, "z_image_turbo_bf16.safetensors");
});

test("rejects an aspect ratio absent from the model descriptor", async () => {
  await assert.rejects(
    registry.prepareImage({
      model: "local/z-image-turbo",
      prompt: "A quiet harbor",
      n: 1,
      aspect_ratio: "2:1",
    }),
    /Unsupported aspect_ratio/
  );
});

test("rejects an unavailable image model instead of falling back", async () => {
  await assert.rejects(
    registry.prepareImage({
      model: "local/flux-2-dev",
      prompt: "A quiet harbor",
      n: 1,
      aspect_ratio: "1:1",
    }),
    /Unsupported image model/
  );
});

test("reloads model descriptors without restarting", async () => {
  const directory = await mkdtemp(join(tmpdir(), "palmier-models-"));
  const descriptorURL = pathToFileURL(join(directory, "experimental.model.json"));
  const workflowURL = pathToFileURL(join(directory, "workflow.json"));
  await writeFile(workflowURL, JSON.stringify({
    prompt: { inputs: { text: "" } },
    latent: { inputs: { width: 1, height: 1, batch_size: 1 } },
  }));

  const descriptor = {
    catalog: {
      id: "local/experimental",
      kind: "image",
      displayName: "First Name",
      allowedEndpoints: ["image"],
      responseShape: "images",
      uiCapabilities: {
        resolutions: null,
        aspectRatios: ["1:1"],
        qualities: null,
        supportsImageReference: false,
        maxImages: 1,
      },
      paidOnly: false,
    },
    execution: {
      engine: "comfy-image",
      workflow: "./workflow.json",
      dimensions: { "1:1": [512, 512] },
      bindings: {
        prompt: { node: "prompt", input: "text" },
        width: { node: "latent", input: "width" },
        height: { node: "latent", input: "height" },
        batchSize: { node: "latent", input: "batch_size" },
      },
    },
  };
  await writeFile(descriptorURL, JSON.stringify(descriptor));
  const dynamicRegistry = new ModelRegistry({ modelsDirectoryURL: pathToFileURL(directory) });

  assert.equal((await dynamicRegistry.catalog())[0].displayName, "First Name");
  descriptor.catalog.displayName = "Second Name";
  await writeFile(descriptorURL, JSON.stringify(descriptor));
  assert.equal((await dynamicRegistry.catalog())[0].displayName, "Second Name");
});
