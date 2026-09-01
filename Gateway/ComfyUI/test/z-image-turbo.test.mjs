import assert from "node:assert/strict";
import test from "node:test";
import {
  configureZImageTurboWorkflow,
  loadZImageTurboWorkflow,
  validateZImageTurboRequest,
} from "../src/z-image-turbo.mjs";

test("configures the official Z-Image Turbo graph for a Palmier request", async () => {
  const request = validateZImageTurboRequest({
    model: "local/z-image-turbo",
    prompt: "  A quiet harbor at sunrise  ",
    n: 3,
    aspect_ratio: "16:9",
    width: 1024,
    height: 576,
  });
  const workflow = configureZImageTurboWorkflow(await loadZImageTurboWorkflow(), request);

  assert.equal(workflow["27"].inputs.text, "A quiet harbor at sunrise");
  assert.equal(workflow["13"].inputs.width, 1024);
  assert.equal(workflow["13"].inputs.height, 576);
  assert.equal(workflow["13"].inputs.batch_size, 3);
  assert.equal(workflow["3"].inputs.steps, 8);
  assert.equal(workflow["28"].inputs.unet_name, "z_image_turbo_bf16.safetensors");
});

test("rejects dimensions that disagree with the aspect ratio", () => {
  assert.throws(
    () => validateZImageTurboRequest({
      model: "local/z-image-turbo",
      prompt: "A quiet harbor",
      n: 1,
      aspect_ratio: "16:9",
      width: 1024,
      height: 1024,
    }),
    /16:9 requires 1024x576/
  );
});

test("rejects an unavailable image model instead of falling back", () => {
  assert.throws(
    () => validateZImageTurboRequest({
      model: "local/flux-2-dev",
      prompt: "A quiet harbor",
      n: 1,
      aspect_ratio: "1:1",
      width: 1024,
      height: 1024,
    }),
    /Unsupported image model/
  );
});
