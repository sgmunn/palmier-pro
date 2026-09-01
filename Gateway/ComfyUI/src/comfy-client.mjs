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
      const response = await this.request(
        new URL(`history/${encodeURIComponent(promptID)}`, this.baseURL),
        undefined,
        "Could not read ComfyUI history."
      );
      const body = await responseJSON(response, "ComfyUI returned invalid history.");
      if (!response.ok) {
        throw gatewayError(`ComfyUI history failed with HTTP ${response.status}.`, "comfy_unavailable");
      }

      const history = body[promptID];
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

  async downloadImage(output, signal) {
    const url = new URL("view", this.baseURL);
    url.searchParams.set("filename", output.filename);
    url.searchParams.set("subfolder", output.subfolder);
    url.searchParams.set("type", output.type);
    const response = await this.request(
      url,
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
