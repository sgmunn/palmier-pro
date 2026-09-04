import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";
import { ModelRegistry } from "../src/model-registry.mjs";
import { createGatewayServer } from "../src/server.mjs";

const modelRegistry = new ModelRegistry({
  modelsDirectoryURL: new URL("../models/", import.meta.url),
});

test("serves the Palmier image contract with bearer authentication", async (context) => {
  let receivedWorkflow;
  const server = await createGatewayServer({
    apiKey: "test-key",
    comfyClient: {
      async generateImages(workflow, count) {
        receivedWorkflow = workflow;
        assert.equal(count, 1);
        return [{ base64: "AQID", contentType: "image/png" }];
      },
    },
    modelRegistry,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  context.after(() => server.close());
  const address = server.address();

  const response = await fetch(`http://127.0.0.1:${address.port}/v1/images/generations`, {
    method: "POST",
    headers: {
      Authorization: "Bearer test-key",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "local/z-image-turbo",
      prompt: "A quiet harbor",
      n: 1,
      aspect_ratio: "1:1",
    }),
  });
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.model, "local/z-image-turbo");
  assert.deepEqual(body.data, [{ index: 0, b64_json: "AQID" }]);
  assert.equal(receivedWorkflow["27"].inputs.text, "A quiet harbor");
});

test("advertises the configured model catalog", async (context) => {
  const server = await createGatewayServer({
    apiKey: "test-key",
    comfyClient: { generateImages: () => assert.fail("must not generate") },
    modelRegistry,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  context.after(() => server.close());
  const address = server.address();

  const response = await fetch(`http://127.0.0.1:${address.port}/v1/palmier/models`, {
    headers: { Authorization: "Bearer test-key" },
  });
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.catalogVersion, 1);
  assert.equal(body.models.length, 2);
  assert.deepEqual(body.models.map((model) => model.id), [
    "local/ltx-2.5-distilled",
    "local/z-image-turbo",
  ]);
  assert.equal(body.models[0].kind, "video");
});

test("serves the asynchronous Palmier video lifecycle", async (context) => {
  let submittedWorkflow;
  const output = { filename: "clip.mp4", subfolder: "palmier", type: "output" };
  const server = await createGatewayServer({
    apiKey: "test-key",
    comfyClient: {
      async submitVideo(workflow, inputImage) {
        submittedWorkflow = workflow;
        assert.equal(inputImage, null);
        return "prompt-1";
      },
      async videoStatus(jobID) {
        assert.equal(jobID, "prompt-1");
        return { status: "completed", output };
      },
      async fetchVideo(receivedOutput) {
        assert.deepEqual(receivedOutput, output);
        return new Response(new Uint8Array([1, 2, 3]), {
          headers: { "Content-Type": "video/mp4", "Content-Length": "3" },
        });
      },
    },
    modelRegistry,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  context.after(() => server.close());
  const address = server.address();
  const origin = `http://127.0.0.1:${address.port}`;

  const createResponse = await fetch(`${origin}/v2/videos`, {
    method: "POST",
    headers: { Authorization: "Bearer test-key", "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "local/ltx-2.5-distilled",
      prompt: "A quiet harbor",
      width: 1366,
      height: 768,
      seconds: "5",
    }),
  });
  const created = await createResponse.json();

  assert.equal(createResponse.status, 200);
  assert.deepEqual(created, {
    id: "prompt-1",
    model: "local/ltx-2.5-distilled",
    status: "queued",
  });
  assert.equal(submittedWorkflow["5"].inputs.text, "A quiet harbor");

  const statusResponse = await fetch(`${origin}/v2/videos/prompt-1`, {
    headers: { Authorization: "Bearer test-key" },
  });
  const status = await statusResponse.json();
  assert.equal(status.status, "completed");
  assert.equal(status.outputs.video_url, `${origin}/v2/videos/prompt-1/content`);

  const videoResponse = await fetch(status.outputs.video_url);
  assert.equal(videoResponse.status, 200);
  assert.equal(videoResponse.headers.get("content-type"), "video/mp4");
  assert.deepEqual(new Uint8Array(await videoResponse.arrayBuffer()), new Uint8Array([1, 2, 3]));
});

test("rejects a missing gateway API key", async (context) => {
  const server = await createGatewayServer({
    apiKey: "test-key",
    comfyClient: { generateImages: () => assert.fail("must not generate") },
    modelRegistry,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  context.after(() => server.close());
  const address = server.address();

  const response = await fetch(`http://127.0.0.1:${address.port}/v1/images/generations`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });

  assert.equal(response.status, 401);
});
