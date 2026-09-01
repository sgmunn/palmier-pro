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
