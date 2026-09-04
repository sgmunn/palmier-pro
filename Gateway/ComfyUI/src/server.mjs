import { createServer as createHTTPServer } from "node:http";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const maximumRequestBytes = 64 * 1024;
const maximumVideoRequestBytes = 64 * 1024 * 1024;

export async function createGatewayServer({ apiKey, comfyClient, modelRegistry }) {
  if (typeof apiKey !== "string" || !apiKey) throw new Error("Gateway API key is required.");
  if (!comfyClient) throw new Error("ComfyUI client is required.");
  if (!modelRegistry) throw new Error("Gateway model registry is required.");

  return createHTTPServer(async (request, response) => {
    try {
      const pathname = new URL(request.url, "http://gateway.invalid").pathname;
      if (request.method === "GET" && request.url === "/health") {
        return sendJSON(response, 200, { status: "ok" });
      }
      const videoContentJobID = pathParameter(pathname, "/v2/videos/", "/content");
      if (request.method === "GET" && videoContentJobID) {
        return sendVideo(response, comfyClient, videoContentJobID, request);
      }
      if (request.headers.authorization !== `Bearer ${apiKey}`) {
        return sendError(response, 401, "unauthorized", "Invalid gateway API key.");
      }
      if (request.method === "GET" && request.url === "/v1/palmier/models") {
        return sendJSON(response, 200, {
          catalogVersion: 1,
          models: await modelRegistry.catalog(),
        });
      }
      if (request.method === "POST" && pathname === "/v2/videos") {
        const payload = JSON.parse(await readBody(request, maximumVideoRequestBytes));
        const prepared = await modelRegistry.prepareVideo(payload);
        const controller = requestAbortController(request);
        const jobID = await comfyClient.submitVideo(
          prepared.workflow,
          prepared.inputImage,
          controller.signal
        );
        return sendJSON(response, 200, {
          id: jobID,
          model: prepared.modelID,
          status: "queued",
        });
      }
      const videoJobID = pathParameter(pathname, "/v2/videos/", "");
      if (request.method === "GET" && videoJobID) {
        const controller = requestAbortController(request);
        const state = await comfyClient.videoStatus(videoJobID, undefined, controller.signal);
        return sendJSON(response, 200, videoJobResponse(request, videoJobID, state));
      }
      if (request.method !== "POST" || pathname !== "/v1/images/generations") {
        return sendError(response, 404, "not_found", "Endpoint not found.");
      }

      const payload = JSON.parse(await readBody(request));
      const prepared = await modelRegistry.prepareImage(payload);
      const controller = requestAbortController(request);
      const images = await comfyClient.generateImages(
        prepared.workflow,
        prepared.count,
        controller.signal
      );
      sendJSON(response, 200, {
        id: randomUUID(),
        object: "list",
        model: prepared.modelID,
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

function requestAbortController(request) {
  const controller = new AbortController();
  request.once("aborted", () => controller.abort());
  return controller;
}

function pathParameter(pathname, prefix, suffix) {
  if (!pathname.startsWith(prefix) || !pathname.endsWith(suffix)) return null;
  const encoded = pathname.slice(prefix.length, pathname.length - suffix.length);
  if (!encoded || encoded.includes("/")) return null;
  try {
    return decodeURIComponent(encoded);
  } catch {
    return null;
  }
}

function videoJobResponse(request, jobID, state) {
  if (state.status === "completed") {
    return {
      id: jobID,
      status: "completed",
      outputs: { video_url: `${requestOrigin(request)}/v2/videos/${encodeURIComponent(jobID)}/content` },
    };
  }
  if (state.status === "failed") {
    return {
      id: jobID,
      status: "failed",
      error: { code: "generation_failed", message: state.message },
    };
  }
  return { id: jobID, status: state.status };
}

function requestOrigin(request) {
  const host = request.headers.host;
  if (typeof host !== "string" || !/^[a-zA-Z0-9.:[\]-]+$/.test(host)) {
    throw Object.assign(new Error("Request has an invalid Host header."), {
      statusCode: 400,
      code: "invalid_request",
    });
  }
  return `http://${host}`;
}

async function sendVideo(response, comfyClient, jobID, request) {
  const controller = requestAbortController(request);
  const state = await comfyClient.videoStatus(jobID, undefined, controller.signal);
  if (state.status !== "completed") {
    return sendError(response, 409, "output_not_ready", "Video output is not ready.");
  }
  const upstream = await comfyClient.fetchVideo(state.output, controller.signal);
  const headers = { "Content-Type": upstream.headers.get("content-type") ?? "video/mp4" };
  const contentLength = upstream.headers.get("content-length");
  if (contentLength) headers["Content-Length"] = contentLength;
  response.writeHead(200, headers);
  await pipeline(Readable.fromWeb(upstream.body), response);
}

function readBody(request, limit = maximumRequestBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let rejected = false;
    request.on("data", (chunk) => {
      if (rejected) return;
      size += chunk.length;
      if (size > limit) {
        rejected = true;
        reject(Object.assign(new Error(`Request body exceeds ${Math.floor(limit / 1024)} KiB.`), {
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
