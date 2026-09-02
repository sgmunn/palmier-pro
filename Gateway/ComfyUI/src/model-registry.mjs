import { randomBytes } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";

export class ModelRegistry {
  constructor({ modelsDirectoryURL } = {}) {
    if (!(modelsDirectoryURL instanceof URL)) {
      throw new Error("Gateway models directory URL is required.");
    }
    this.modelsDirectoryURL = modelsDirectoryURL;
  }

  async catalog() {
    return (await this.loadDescriptors()).map((descriptor) => descriptor.catalog);
  }

  async prepareImage(value) {
    const descriptors = await this.loadDescriptors();
    const modelID = typeof value?.model === "string" ? value.model : "";
    const descriptor = descriptors.find((candidate) => candidate.catalog.id === modelID);
    if (!descriptor || descriptor.catalog.kind !== "image") {
      throw requestError(`Unsupported image model '${String(value?.model ?? "")}'.`);
    }
    return configureImageWorkflow(descriptor, value);
  }

  async loadDescriptors() {
    let names;
    try {
      names = (await readdir(this.modelsDirectoryURL))
        .filter((name) => name.endsWith(".model.json"))
        .sort();
    } catch (error) {
      throw configurationError(`Could not read gateway model directory: ${error.message}`);
    }

    const descriptors = await Promise.all(names.map(async (name) => {
      const url = new URL(name, ensureDirectoryURL(this.modelsDirectoryURL));
      let descriptor;
      try {
        descriptor = JSON.parse(await readFile(url, "utf8"));
      } catch (error) {
        throw configurationError(`Could not load model descriptor '${name}': ${error.message}`);
      }
      validateDescriptor(descriptor, name, url);
      return { ...descriptor, descriptorURL: url };
    }));

    const ids = new Set();
    for (const descriptor of descriptors) {
      if (!ids.add(descriptor.catalog.id)) {
        throw configurationError(`Duplicate gateway model ID '${descriptor.catalog.id}'.`);
      }
    }
    return descriptors;
  }
}

async function configureImageWorkflow(descriptor, value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw requestError("Request body must be a JSON object.");
  }
  const prompt = typeof value.prompt === "string" ? value.prompt.trim() : "";
  const maximumPromptLength = descriptor.execution.maximumPromptLength ?? 10_000;
  if (!prompt) throw requestError("Prompt must not be empty.");
  if (prompt.length > maximumPromptLength) {
    throw requestError(`Prompt exceeds ${maximumPromptLength} characters.`);
  }

  const capabilities = descriptor.catalog.uiCapabilities;
  if (!Number.isInteger(value.n) || value.n < 1 || value.n > capabilities.maxImages) {
    throw requestError(`n must be an integer from 1 through ${capabilities.maxImages}.`);
  }
  if (typeof value.aspect_ratio !== "string") {
    throw requestError("aspect_ratio is required.");
  }
  const dimensions = descriptor.execution.dimensions[value.aspect_ratio];
  if (!dimensions) throw requestError(`Unsupported aspect_ratio '${value.aspect_ratio}'.`);
  validateOptionalSelection("resolution", value.resolution, capabilities.resolutions);
  validateOptionalSelection("quality", value.quality, capabilities.qualities);

  const workflowURL = new URL(descriptor.execution.workflow, descriptor.descriptorURL);
  let workflow;
  try {
    workflow = JSON.parse(await readFile(workflowURL, "utf8"));
  } catch (error) {
    throw configurationError(
      `Could not load workflow for '${descriptor.catalog.id}': ${error.message}`
    );
  }

  setBinding(workflow, descriptor.execution.bindings.prompt, prompt, "prompt");
  setBinding(workflow, descriptor.execution.bindings.width, dimensions[0], "width");
  setBinding(workflow, descriptor.execution.bindings.height, dimensions[1], "height");
  setBinding(workflow, descriptor.execution.bindings.batchSize, value.n, "batchSize");
  if (descriptor.execution.bindings.seed) {
    setBinding(workflow, descriptor.execution.bindings.seed, randomSeed(), "seed");
  }
  if (value.resolution != null && descriptor.execution.bindings.resolution) {
    setBinding(workflow, descriptor.execution.bindings.resolution, value.resolution, "resolution");
  }
  if (value.quality != null && descriptor.execution.bindings.quality) {
    setBinding(workflow, descriptor.execution.bindings.quality, value.quality, "quality");
  }

  return { workflow, count: value.n, modelID: descriptor.catalog.id };
}

function validateDescriptor(descriptor, name, descriptorURL) {
  const catalog = descriptor?.catalog;
  const execution = descriptor?.execution;
  if (!catalog || typeof catalog !== "object") {
    throw configurationError(`Model descriptor '${name}' has no catalog entry.`);
  }
  for (const field of ["id", "kind", "displayName", "responseShape"]) {
    if (typeof catalog[field] !== "string" || !catalog[field]) {
      throw configurationError(`Model descriptor '${name}' has an invalid catalog.${field}.`);
    }
  }
  if (!Array.isArray(catalog.allowedEndpoints) || !catalog.uiCapabilities) {
    throw configurationError(`Model descriptor '${name}' has invalid catalog capabilities.`);
  }
  if (catalog.kind !== "image") {
    throw configurationError(`Model '${catalog.id}' uses unsupported kind '${catalog.kind}'.`);
  }
  if (execution?.engine !== "comfy-image" || typeof execution.workflow !== "string") {
    throw configurationError(`Image model '${catalog.id}' must configure a comfy-image workflow.`);
  }
  if (!execution.dimensions || typeof execution.dimensions !== "object") {
    throw configurationError(`Image model '${catalog.id}' has no dimensions map.`);
  }
  const capabilities = catalog.uiCapabilities;
  if (!Array.isArray(capabilities.aspectRatios) || !Number.isInteger(capabilities.maxImages)) {
    throw configurationError(`Image model '${catalog.id}' has invalid image capabilities.`);
  }
  for (const aspectRatio of capabilities.aspectRatios) {
    const dimensions = execution.dimensions[aspectRatio];
    if (!Array.isArray(dimensions) || dimensions.length !== 2 ||
        !dimensions.every((dimension) => Number.isInteger(dimension) && dimension > 0)) {
      throw configurationError(`Image model '${catalog.id}' has invalid dimensions for '${aspectRatio}'.`);
    }
  }
  for (const binding of ["prompt", "width", "height", "batchSize"]) {
    validateBinding(execution.bindings?.[binding], catalog.id, binding);
  }
  for (const binding of ["seed", "resolution", "quality"]) {
    if (execution.bindings?.[binding]) validateBinding(execution.bindings[binding], catalog.id, binding);
  }
  if (capabilities.resolutions?.length && !execution.bindings?.resolution) {
    throw configurationError(`Image model '${catalog.id}' advertises resolutions without a binding.`);
  }
  if (capabilities.qualities?.length && !execution.bindings?.quality) {
    throw configurationError(`Image model '${catalog.id}' advertises qualities without a binding.`);
  }
  if (!(descriptorURL instanceof URL)) throw configurationError(`Model descriptor '${name}' has no URL.`);
}

function validateBinding(binding, modelID, name) {
  if (!binding || typeof binding.node !== "string" || typeof binding.input !== "string") {
    throw configurationError(`Image model '${modelID}' has an invalid '${name}' binding.`);
  }
}

function setBinding(workflow, binding, value, name) {
  const node = workflow?.[binding.node];
  if (!node?.inputs || !(binding.input in node.inputs)) {
    throw configurationError(
      `Workflow binding '${name}' does not resolve to node ${binding.node}.${binding.input}.`
    );
  }
  node.inputs[binding.input] = value;
}

function validateOptionalSelection(name, value, allowed) {
  if (value == null) return;
  if (!Array.isArray(allowed) || !allowed.includes(value)) {
    throw requestError(`Unsupported ${name} '${value}'.`);
  }
}

function ensureDirectoryURL(url) {
  return url.href.endsWith("/") ? url : new URL(`${url.href}/`);
}

function randomSeed() {
  return randomBytes(6).readUIntBE(0, 6);
}

function requestError(message) {
  return Object.assign(new Error(message), { statusCode: 400, code: "invalid_request" });
}

function configurationError(message) {
  return Object.assign(new Error(message), { statusCode: 500, code: "invalid_model_configuration" });
}
