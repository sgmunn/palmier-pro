import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";

export const zImageTurboModelID = "local/z-image-turbo";

const supportedDimensions = new Map([
  ["1:1", [1024, 1024]],
  ["16:9", [1024, 576]],
  ["9:16", [576, 1024]],
  ["4:3", [1024, 768]],
  ["3:4", [768, 1024]],
]);

const workflowURL = new URL("../workflows/z-image-turbo-api.json", import.meta.url);

export async function loadZImageTurboWorkflow() {
  return JSON.parse(await readFile(workflowURL, "utf8"));
}

export function validateZImageTurboRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw invalidRequest("Request body must be a JSON object.");
  }
  if (value.model !== zImageTurboModelID) {
    throw invalidRequest(`Unsupported image model '${String(value.model ?? "")}'.`);
  }

  const prompt = typeof value.prompt === "string" ? value.prompt.trim() : "";
  if (!prompt) throw invalidRequest("Prompt must not be empty.");
  if (prompt.length > 10_000) throw invalidRequest("Prompt exceeds 10000 characters.");

  if (!Number.isInteger(value.n) || value.n < 1 || value.n > 4) {
    throw invalidRequest("n must be an integer from 1 through 4.");
  }
  if (typeof value.aspect_ratio !== "string") {
    throw invalidRequest("aspect_ratio is required.");
  }
  const dimensions = supportedDimensions.get(value.aspect_ratio);
  if (!dimensions) throw invalidRequest(`Unsupported aspect_ratio '${value.aspect_ratio}'.`);
  if (value.width !== dimensions[0] || value.height !== dimensions[1]) {
    throw invalidRequest(
      `${value.aspect_ratio} requires ${dimensions[0]}x${dimensions[1]} output.`
    );
  }
  if (value.resolution != null || value.quality != null) {
    throw invalidRequest("Z-Image Turbo does not accept resolution or quality options.");
  }

  return {
    prompt,
    count: value.n,
    aspectRatio: value.aspect_ratio,
    width: value.width,
    height: value.height,
  };
}

export function configureZImageTurboWorkflow(template, request) {
  const workflow = structuredClone(template);
  requireNode(workflow, "3", "KSampler").inputs.seed = randomSeed();
  const latent = requireNode(workflow, "13", "EmptySD3LatentImage").inputs;
  latent.width = request.width;
  latent.height = request.height;
  latent.batch_size = request.count;
  requireNode(workflow, "27", "CLIPTextEncode").inputs.text = request.prompt;
  return workflow;
}

function requireNode(workflow, nodeID, classType) {
  const node = workflow[nodeID];
  if (!node || node.class_type !== classType || !node.inputs) {
    throw new Error(`Z-Image Turbo workflow is missing ${classType} node ${nodeID}.`);
  }
  return node;
}

function randomSeed() {
  return randomBytes(6).readUIntBE(0, 6);
}

function invalidRequest(message) {
  return Object.assign(new Error(message), { statusCode: 400, code: "invalid_request" });
}
