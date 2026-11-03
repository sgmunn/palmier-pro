import assert from "node:assert/strict";
import test from "node:test";
import { ModelRegistry } from "../src/model-registry.mjs";

const registry = new ModelRegistry({
  modelsDirectoryURL: new URL("../models/", import.meta.url),
});

test("configures Kokoro speech for Palmier's audio request", async () => {
  const prepared = await registry.prepareSpeech({
    model: "local/kokoro-82m",
    input: "  Palmier local speech generation is ready.  ",
    voice: "af_heart",
    response_format: "mp3",
  });

  assert.equal(prepared.modelID, "local/kokoro-82m");
  assert.equal(prepared.workflow["1"].inputs.speaker_name, "af_heart");
  assert.equal(prepared.workflow["2"].inputs.text, "Palmier local speech generation is ready.");
  assert.equal(prepared.workflow["2"].inputs.lang, "English");
  assert.equal(prepared.workflow["3"].class_type, "SaveAudioAdvanced");
  assert.equal(prepared.workflow["3"].inputs.format, "mp3");
  assert.equal(prepared.workflow["3"].inputs["format.quality"], "128k");
});

test("rejects unsupported Kokoro request values", async () => {
  const base = {
    model: "local/kokoro-82m",
    input: "Palmier local speech generation is ready.",
    voice: "af_heart",
    response_format: "mp3",
  };

  await assert.rejects(registry.prepareSpeech({ ...base, input: " " }), /must not be empty/);
  await assert.rejects(registry.prepareSpeech({ ...base, voice: "am_adam" }), /Unsupported voice/);
  await assert.rejects(registry.prepareSpeech({ ...base, response_format: "wav" }), /Unsupported response_format/);
  await assert.rejects(registry.prepareSpeech({ ...base, model: "missing" }), /Unsupported audio model/);
});
