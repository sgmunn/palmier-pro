import assert from "node:assert/strict";
import test from "node:test";
import { once } from "node:events";
import { createGatewayServer } from "../src/server.mjs";

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
      width: 1024,
      height: 1024,
    }),
  });
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.model, "local/z-image-turbo");
  assert.deepEqual(body.data, [{ index: 0, b64_json: "AQID" }]);
  assert.equal(receivedWorkflow["27"].inputs.text, "A quiet harbor");
});

test("rejects a missing gateway API key", async (context) => {
  const server = await createGatewayServer({
    apiKey: "test-key",
    comfyClient: { generateImages: () => assert.fail("must not generate") },
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
