import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";

export class ComfyClient {
  constructor({
    baseURL = "http://127.0.0.1:8188",
    fetchImplementation = fetch,
    pollIntervalMilliseconds = 500,
    timeoutMilliseconds = 15 * 60 * 1000,
  } = {}) {
    this.baseURL = new URL(baseURL);
    this.fetch = fetchImplementation;
    this.pollIntervalMilliseconds = pollIntervalMilliseconds;
    this.timeoutMilliseconds = timeoutMilliseconds;
  }

  async generateImages(workflow, expectedCount, signal) {
    const promptID = await this.submit(workflow, signal);
    const outputs = await this.waitForImages(promptID, signal);
    if (outputs.length !== expectedCount) {
      throw gatewayError(
        `ComfyUI returned ${outputs.length} image${outputs.length === 1 ? "" : "s"}; expected ${expectedCount}.`,
        "incomplete_output"
      );
    }
    return Promise.all(outputs.map((output) => this.downloadImage(output, signal)));
  }

  async submitVideo(workflow, inputImage, signal) {
    if (inputImage) {
      const uploadedPath = await this.uploadImage(inputImage.base64, signal);
      setWorkflowInput(workflow, inputImage.binding, uploadedPath);
    }
    return this.submit(workflow, signal);
  }

  async uploadImage(base64, signal) {
    const image = decodeImage(base64);
    const filename = `first-frame-${randomUUID()}.${image.extension}`;
    const form = new FormData();
    form.set("image", new Blob([image.bytes], { type: image.contentType }), filename);
    form.set("type", "input");
    form.set("subfolder", "palmier");
    const response = await this.request(
      new URL("upload/image", this.baseURL),
      { method: "POST", body: form, signal },
      "Could not upload the starting frame to ComfyUI."
    );
    const body = await responseJSON(response, "ComfyUI returned an invalid image-upload response.");
    if (!response.ok || typeof body.name !== "string" || typeof body.subfolder !== "string") {
      throw gatewayError("ComfyUI rejected the starting frame.", "input_upload_failed");
    }
    return body.subfolder ? `${body.subfolder}/${body.name}` : body.name;
  }

  async videoStatus(promptID, outputNodeID, signal) {
    const history = await this.history(promptID, signal);
    if (!history) return { status: "in_progress" };
    if (history.status?.status_str === "error") {
      return { status: "failed", message: comfyFailureMessage(history.status) };
    }
    if (!history.status?.completed) return { status: "in_progress" };

    const output = collectVideos(history.outputs, outputNodeID)[0];
    if (!output) {
      return { status: "failed", message: "ComfyUI completed without a video output." };
    }
    return { status: "completed", output };
  }

  async fetchVideo(output, signal) {
    const response = await this.request(
      outputURL(this.baseURL, output),
      { signal },
      "Could not download the ComfyUI video."
    );
    if (!response.ok) {
      throw gatewayError(`ComfyUI video download failed with HTTP ${response.status}.`, "output_download_failed");
    }
    const contentType = response.headers.get("content-type")?.split(";", 1)[0];
    if (!contentType?.startsWith("video/")) {
      throw gatewayError("ComfyUI output is not a video.", "invalid_output");
    }
    return response;
  }

  async submit(workflow, signal) {
    const response = await this.request(
      new URL("prompt", this.baseURL),
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt: workflow }),
        signal,
      },
      "Could not submit the ComfyUI workflow."
    );
    const body = await responseJSON(response, "ComfyUI rejected the workflow.");
    if (!response.ok) {
      const details = body.error ?? body.node_errors ?? response.statusText;
      throw gatewayError(`ComfyUI rejected the workflow: ${stringify(details)}`, "workflow_rejected");
    }
    if (typeof body.prompt_id !== "string" || !body.prompt_id) {
      throw gatewayError("ComfyUI returned no prompt ID.", "invalid_comfy_response");
    }
    return body.prompt_id;
  }

  async waitForImages(promptID, signal) {
    const deadline = Date.now() + this.timeoutMilliseconds;
    while (Date.now() < deadline) {
      if (signal?.aborted) throw signal.reason ?? new DOMException("Aborted", "AbortError");
      const history = await this.history(promptID, signal);
      if (history) {
        if (history.status?.status_str === "error") {
          throw gatewayError(comfyFailureMessage(history.status), "generation_failed");
        }
        if (history.status?.completed) return collectImages(history.outputs);
      }
      await delay(this.pollIntervalMilliseconds, undefined, { signal });
    }
    throw gatewayError("Timed out waiting for ComfyUI image generation.", "generation_timeout", 504);
  }

  async history(promptID, signal) {
    const response = await this.request(
      new URL(`history/${encodeURIComponent(promptID)}`, this.baseURL),
      { signal },
      "Could not read ComfyUI history."
    );
    const body = await responseJSON(response, "ComfyUI returned invalid history.");
    if (!response.ok) {
      throw gatewayError(`ComfyUI history failed with HTTP ${response.status}.`, "comfy_unavailable");
    }
    return body[promptID] ?? null;
  }

  async downloadImage(output, signal) {
    const response = await this.request(
      outputURL(this.baseURL, output),
      { signal },
      "Could not download the ComfyUI image."
    );
    if (!response.ok) {
      throw gatewayError(`ComfyUI image download failed with HTTP ${response.status}.`, "output_download_failed");
    }
    const contentType = response.headers.get("content-type")?.split(";", 1)[0];
    if (!contentType?.startsWith("image/")) {
      throw gatewayError("ComfyUI output is not an image.", "invalid_output");
    }
    return {
      base64: Buffer.from(await response.arrayBuffer()).toString("base64"),
      contentType,
    };
  }

  async request(url, init, failureMessage) {
    try {
      return await this.fetch(url, init);
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw gatewayError(failureMessage, "comfy_unavailable");
    }
  }
}

function setWorkflowInput(workflow, binding, value) {
  const node = workflow?.[binding?.node];
  if (!node?.inputs || !(binding.input in node.inputs)) {
    throw gatewayError("The video workflow has an invalid starting-frame binding.", "invalid_model_configuration", 500);
  }
  node.inputs[binding.input] = value;
}

function decodeImage(base64) {
  if (typeof base64 !== "string" || base64.length === 0 || base64.length > 56 * 1024 * 1024 ||
      base64.length % 4 !== 0 || !/^[a-zA-Z0-9+/]*={0,2}$/.test(base64)) {
    throw gatewayError("The starting frame is not valid base64 image data.", "invalid_request", 400);
  }
  const bytes = Buffer.from(base64, "base64");
  if (bytes.subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47]))) {
    return { bytes, extension: "png", contentType: "image/png" };
  }
  if (bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) {
    return { bytes, extension: "jpg", contentType: "image/jpeg" };
  }
  if (bytes.subarray(0, 4).toString("ascii") === "GIF8") {
    return { bytes, extension: "gif", contentType: "image/gif" };
  }
  if (bytes.length >= 12 && bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
      bytes.subarray(8, 12).toString("ascii") === "WEBP") {
    return { bytes, extension: "webp", contentType: "image/webp" };
  }
  throw gatewayError("The starting frame is not a supported image.", "invalid_request", 400);
}

function outputURL(baseURL, output) {
  const url = new URL("view", baseURL);
  url.searchParams.set("filename", output.filename);
  url.searchParams.set("subfolder", output.subfolder);
  url.searchParams.set("type", output.type);
  return url;
}

function collectImages(outputs) {
  if (!outputs || typeof outputs !== "object") return [];
  return Object.values(outputs).flatMap((output) =>
    Array.isArray(output?.images)
      ? output.images.filter(
          (image) =>
            image &&
            typeof image.filename === "string" &&
            typeof image.subfolder === "string" &&
            typeof image.type === "string"
        )
      : []
  );
}

function collectVideos(outputs, outputNodeID) {
  if (!outputs || typeof outputs !== "object") return [];
  const candidates = outputNodeID == null ? Object.values(outputs) : [outputs[outputNodeID]];
  return candidates.flatMap((output) =>
    Array.isArray(output?.images)
      ? output.images.filter(
          (item) => validOutput(item) && /\.(mp4|mkv|mov|webm)$/i.test(item.filename)
        )
      : []
  );
}

function validOutput(value) {
  return value && typeof value.filename === "string" &&
    typeof value.subfolder === "string" && typeof value.type === "string";
}

function comfyFailureMessage(status) {
  const messages = Array.isArray(status.messages) ? status.messages : [];
  const executionError = messages.find((message) => message?.[0] === "execution_error")?.[1];
  return executionError?.exception_message
    ? `ComfyUI generation failed: ${executionError.exception_message}`
    : "ComfyUI generation failed.";
}

async function responseJSON(response, fallbackMessage) {
  try {
    return await response.json();
  } catch {
    throw gatewayError(fallbackMessage, "invalid_comfy_response");
  }
}

function stringify(value) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function gatewayError(message, code, statusCode = 502) {
  return Object.assign(new Error(message), { statusCode, code });
}
