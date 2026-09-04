import assert from "node:assert/strict";
import test from "node:test";
import { ModelRegistry } from "../src/model-registry.mjs";

const registry = new ModelRegistry({
  modelsDirectoryURL: new URL("../models/", import.meta.url),
});

test("configures LTX 2.5 for Palmier's five-second video request", async () => {
  const prepared = await registry.prepareVideo({
    model: "local/ltx-2.5-distilled",
    prompt: "  A red ball rolls across a wooden table  ",
    width: 1366,
    height: 768,
    seconds: "5",
    generate_audio: false,
  });
  const workflow = prepared.workflow;

  assert.equal(prepared.modelID, "local/ltx-2.5-distilled");
  assert.equal(workflow["5"].inputs.text, "A red ball rolls across a wooden table");
  assert.equal(workflow["8"].inputs.width, 1376);
  assert.equal(workflow["8"].inputs.height, 768);
  assert.equal(workflow["8"].inputs.length, 121);
  assert.equal(workflow["9"].inputs.frames_number, 121);
  assert.equal(workflow["7"].inputs.frame_rate, 24);
  assert.equal(workflow["19"].inputs.fps, 24);
  assert.equal(workflow["21"].inputs.width, 1366);
  assert.equal(workflow["21"].inputs.height, 768);
  assert.equal("audio" in workflow["19"].inputs, false);
  assert.equal(prepared.inputImage, null);
});

test("selects the LTX image-to-video graph for a starting frame", async () => {
  const prepared = await registry.prepareVideo({
    model: "local/ltx-2.5-distilled",
    prompt: "The cat waves",
    width: 1366,
    height: 768,
    seconds: "5",
    frame_images: [{ input_image: "iVBORw0KGgo=", frame: 0 }],
  });

  assert.equal(prepared.workflow["8"].class_type, "LTXVImgToVideo");
  assert.deepEqual(prepared.workflow["8"].inputs.image, ["22", 0]);
  assert.deepEqual(prepared.workflow["10"].inputs.video_latent, ["8", 2]);
  assert.deepEqual(prepared.workflow["12"].inputs.positive, ["8", 0]);
  assert.equal(prepared.inputImage.base64, "iVBORw0KGgo=");
  assert.deepEqual(prepared.inputImage.binding, { node: "22", input: "image" });
});

test("rejects unsupported LTX request shapes", async () => {
  const base = {
    model: "local/ltx-2.5-distilled",
    prompt: "A red ball rolls across a wooden table",
    width: 1366,
    height: 768,
    seconds: "5",
  };

  await assert.rejects(registry.prepareVideo({ ...base, seconds: "10" }), /Unsupported video duration/);
  await assert.rejects(registry.prepareVideo({ ...base, generate_audio: true }), /does not generate audio/);
  await assert.rejects(
    registry.prepareVideo({ ...base, frame_images: [{ input_image: "AQID", frame: 1 }] }),
    /frame 0/
  );
  await assert.rejects(
    registry.prepareVideo({
      ...base,
      frame_images: [
        { input_image: "AQID", frame: 0 },
        { input_image: "AQID", frame: 1 },
      ],
    }),
    /at most one/
  );
});
