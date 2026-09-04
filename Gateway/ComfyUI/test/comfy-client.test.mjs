import assert from "node:assert/strict";
import test from "node:test";
import { ComfyClient } from "../src/comfy-client.mjs";

test("submits, polls, and downloads the exact completed image set", async () => {
  const requests = [];
  const client = new ComfyClient({
    pollIntervalMilliseconds: 1,
    fetchImplementation: async (url, init = {}) => {
      requests.push({ url: String(url), init });
      if (String(url).endsWith("/prompt")) {
        return Response.json({ prompt_id: "prompt-1", number: 1 });
      }
      if (String(url).endsWith("/history/prompt-1")) {
        return Response.json({
          "prompt-1": {
            status: { completed: true, status_str: "success" },
            outputs: {
              9: {
                images: [
                  { filename: "one.png", subfolder: "palmier", type: "output" },
                  { filename: "two.png", subfolder: "palmier", type: "output" },
                ],
              },
            },
          },
        });
      }
      return new Response(new Uint8Array([1, 2, 3]), {
        headers: { "Content-Type": "image/png" },
      });
    },
  });

  const images = await client.generateImages({ 1: { class_type: "Example", inputs: {} } }, 2);

  assert.deepEqual(images.map((image) => image.base64), ["AQID", "AQID"]);
  assert.equal(requests.filter((request) => request.url.includes("/view?")).length, 2);
  assert.equal(requests.find((request) => request.url.includes("/history/"))?.init.signal, undefined);
});

test("reports and downloads a completed ComfyUI video", async () => {
  const output = { filename: "clip.mp4", subfolder: "palmier", type: "output" };
  const client = new ComfyClient({
    fetchImplementation: async (url) => {
      if (String(url).includes("/history/")) {
        return Response.json({
          "prompt-1": {
            status: { completed: true, status_str: "success" },
            outputs: { 20: { images: [output], animated: [true] } },
          },
        });
      }
      return new Response(new Uint8Array([1, 2, 3]), {
        headers: { "Content-Type": "video/mp4" },
      });
    },
  });

  const state = await client.videoStatus("prompt-1");
  assert.deepEqual(state, { status: "completed", output });
  const response = await client.fetchVideo(state.output);
  assert.equal(response.headers.get("content-type"), "video/mp4");
});

test("uploads and binds a starting frame before submitting video", async () => {
  const requests = [];
  const client = new ComfyClient({
    fetchImplementation: async (url, init = {}) => {
      requests.push({ url: String(url), init });
      if (String(url).endsWith("/upload/image")) {
        assert.equal(init.body.get("type"), "input");
        assert.equal(init.body.get("subfolder"), "palmier");
        return Response.json({ name: "first.png", subfolder: "palmier", type: "input" });
      }
      const body = JSON.parse(init.body);
      assert.equal(body.prompt["22"].inputs.image, "palmier/first.png");
      return Response.json({ prompt_id: "prompt-1" });
    },
  });
  const workflow = { "22": { class_type: "LoadImage", inputs: { image: "placeholder.png" } } };

  const promptID = await client.submitVideo(workflow, {
    base64: "iVBORw0KGgo=",
    binding: { node: "22", input: "image" },
  });

  assert.equal(promptID, "prompt-1");
  assert.equal(requests.length, 2);
});

test("rejects invalid starting-frame data before upload", async () => {
  const client = new ComfyClient({ fetchImplementation: () => assert.fail("must not upload") });
  await assert.rejects(
    client.submitVideo({}, { base64: "AQID", binding: { node: "22", input: "image" } }),
    (error) => error.code === "invalid_request" && /supported image/.test(error.message)
  );
});

test("refuses partial ComfyUI output", async () => {
  const client = new ComfyClient({
    pollIntervalMilliseconds: 1,
    fetchImplementation: async (url) => {
      if (String(url).endsWith("/prompt")) return Response.json({ prompt_id: "prompt-1" });
      return Response.json({
        "prompt-1": {
          status: { completed: true, status_str: "success" },
          outputs: { 9: { images: [{ filename: "one.png", subfolder: "", type: "output" }] } },
        },
      });
    },
  });

  await assert.rejects(() => client.generateImages({}, 2), /returned 1 image; expected 2/);
});

test("reports an unavailable ComfyUI service", async () => {
  const client = new ComfyClient({
    fetchImplementation: async () => {
      throw new TypeError("connection refused");
    },
  });

  await assert.rejects(
    () => client.generateImages({}, 1),
    (error) => error.code === "comfy_unavailable" && /Could not submit/.test(error.message)
  );
});
