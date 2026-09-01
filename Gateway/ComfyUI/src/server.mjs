import { createServer as createHTTPServer } from "node:http";
import { randomUUID } from "node:crypto";
import {
  configureZImageTurboWorkflow,
  loadZImageTurboWorkflow,
  validateZImageTurboRequest,
  zImageTurboModelID,
} from "./z-image-turbo.mjs";

const maximumRequestBytes = 64 * 1024;

export async function createGatewayServer({ apiKey, comfyClient }) {
  if (typeof apiKey !== "string" || !apiKey) throw new Error("Gateway API key is required.");
  if (!comfyClient) throw new Error("ComfyUI client is required.");
  const workflowTemplate = await loadZImageTurboWorkflow();

  return createHTTPServer(async (request, response) => {
    try {
      if (request.method === "GET" && request.url === "/health") {
        return sendJSON(response, 200, { status: "ok" });
      }
      if (request.method !== "POST" || request.url !== "/v1/images/generations") {
        return sendError(response, 404, "not_found", "Endpoint not found.");
      }
      if (request.headers.authorization !== `Bearer ${apiKey}`) {
        return sendError(response, 401, "unauthorized", "Invalid gateway API key.");
      }

      const payload = JSON.parse(await readBody(request));
      const imageRequest = validateZImageTurboRequest(payload);
      const workflow = configureZImageTurboWorkflow(workflowTemplate, imageRequest);
      const controller = new AbortController();
      request.once("aborted", () => controller.abort());
      const images = await comfyClient.generateImages(workflow, imageRequest.count, controller.signal);
      sendJSON(response, 200, {
        id: randomUUID(),
        object: "list",
        model: zImageTurboModelID,
        data: images.map((image, index) => ({ index, b64_json: image.base64 })),
      });
    } catch (error) {
      if (response.headersSent || response.destroyed) return;
      if (error instanceof SyntaxError) {
        return sendError(response, 400, "invalid_json", "Request body is not valid JSON.");
      }
      if (error?.name === "AbortError") return response.destroy();
      sendError(
        response,
        Number.isInteger(error?.statusCode) ? error.statusCode : 500,
        typeof error?.code === "string" ? error.code : "internal_error",
        error instanceof Error ? error.message : "Gateway failed."
      );
    }
  });
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let rejected = false;
    request.on("data", (chunk) => {
      if (rejected) return;
      size += chunk.length;
      if (size > maximumRequestBytes) {
        rejected = true;
        reject(Object.assign(new Error("Request body exceeds 64 KiB."), {
          statusCode: 413,
          code: "request_too_large",
        }));
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (!rejected) resolve(Buffer.concat(chunks).toString("utf8"));
    });
    request.on("error", reject);
  });
}

function sendError(response, statusCode, code, message) {
  sendJSON(response, statusCode, { error: { code, message, type: "gateway_error" } });
}

function sendJSON(response, statusCode, value) {
  const body = JSON.stringify(value);
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}
