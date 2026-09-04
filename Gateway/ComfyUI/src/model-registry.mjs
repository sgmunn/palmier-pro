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

  async prepareVideo(value) {
    const descriptors = await this.loadDescriptors();
    const modelID = typeof value?.model === "string" ? value.model : "";
    const descriptor = descriptors.find((candidate) => candidate.catalog.id === modelID);
    if (!descriptor || descriptor.catalog.kind !== "video") {
      throw requestError(`Unsupported video model '${String(value?.model ?? "")}'.`);
    }
    return configureVideoWorkflow(descriptor, value);
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
  const prompt = validatePrompt(descriptor, value);

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

  const workflow = await loadWorkflow(descriptor);

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

async function configureVideoWorkflow(descriptor, value) {
  const prompt = validatePrompt(descriptor, value);
  if (!Number.isInteger(value.width) || !Number.isInteger(value.height)) {
    throw requestError("width and height must be integers.");
  }
  const requestedDimensions = `${value.width}x${value.height}`;
  const renderDimensions = descriptor.execution.requestDimensions[requestedDimensions];
  if (!renderDimensions) throw requestError(`Unsupported video dimensions '${requestedDimensions}'.`);
  if (typeof value.seconds !== "string") throw requestError("seconds is required.");
  const frameCount = descriptor.execution.durationFrames[value.seconds];
  if (!Number.isInteger(frameCount)) throw requestError(`Unsupported video duration '${value.seconds}'.`);
  if (value.generate_audio != null && value.generate_audio !== false) {
    throw requestError("This video model does not generate audio.");
  }
  const frameImages = value.frame_images ?? [];
  if (!Array.isArray(frameImages) || frameImages.length > 1) {
    throw requestError("This video model supports at most one starting frame.");
  }
  if (frameImages.length > 0 && descriptor.catalog.uiCapabilities.supportsFirstFrame !== true) {
    throw requestError("This video model does not support a starting frame.");
  }
  const firstFrame = frameImages[0];
  if (firstFrame && (firstFrame.frame !== 0 || typeof firstFrame.input_image !== "string" ||
      !firstFrame.input_image)) {
    throw requestError("The starting frame must contain a base64 image at frame 0.");
  }

  const workflowPath = firstFrame
    ? descriptor.execution.workflows.firstFrame
    : descriptor.execution.workflows.text;
  const workflow = await loadWorkflow(descriptor, workflowPath);
  const bindings = descriptor.execution.bindings;
  setBinding(workflow, bindings.prompt, prompt, "prompt");
  setBinding(workflow, bindings.width, renderDimensions[0], "width");
  setBinding(workflow, bindings.height, renderDimensions[1], "height");
  setBindings(workflow, bindings.frameCount, frameCount, "frameCount");
  setBindings(workflow, bindings.frameRate, descriptor.execution.frameRate, "frameRate");
  setBinding(workflow, bindings.outputWidth, value.width, "outputWidth");
  setBinding(workflow, bindings.outputHeight, value.height, "outputHeight");
  if (bindings.seed) setBinding(workflow, bindings.seed, randomSeed(), "seed");

  return {
    workflow,
    modelID: descriptor.catalog.id,
    inputImage: firstFrame ? {
      base64: firstFrame.input_image,
      binding: bindings.inputImage,
    } : null,
  };
}

function validatePrompt(descriptor, value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw requestError("Request body must be a JSON object.");
  }
  const prompt = typeof value.prompt === "string" ? value.prompt.trim() : "";
  const maximumPromptLength = descriptor.execution.maximumPromptLength ?? 10_000;
  if (!prompt) throw requestError("Prompt must not be empty.");
  if (prompt.length > maximumPromptLength) {
    throw requestError(`Prompt exceeds ${maximumPromptLength} characters.`);
  }
  return prompt;
}

async function loadWorkflow(descriptor, path = descriptor.execution.workflow) {
  const workflowURL = new URL(path, descriptor.descriptorURL);
  try {
    return JSON.parse(await readFile(workflowURL, "utf8"));
  } catch (error) {
    throw configurationError(
      `Could not load workflow for '${descriptor.catalog.id}': ${error.message}`
    );
  }
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
  if (catalog.kind === "image") return validateImageDescriptor(descriptor);
  if (catalog.kind === "video") return validateVideoDescriptor(descriptor);
  throw configurationError(`Model '${catalog.id}' uses unsupported kind '${catalog.kind}'.`);
}

function validateImageDescriptor(descriptor) {
  const { catalog, execution } = descriptor;
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
}

function validateVideoDescriptor(descriptor) {
  const { catalog, execution } = descriptor;
  if (execution?.engine !== "comfy-video" || typeof execution.workflows?.text !== "string") {
    throw configurationError(`Video model '${catalog.id}' must configure a text workflow.`);
  }
  if (!execution.requestDimensions || typeof execution.requestDimensions !== "object") {
    throw configurationError(`Video model '${catalog.id}' has no request dimensions map.`);
  }
  for (const [requestDimensions, renderDimensions] of Object.entries(execution.requestDimensions)) {
    if (!/^\d+x\d+$/.test(requestDimensions) || !validDimensions(renderDimensions)) {
      throw configurationError(`Video model '${catalog.id}' has invalid dimensions for '${requestDimensions}'.`);
    }
  }
  if (!execution.durationFrames || typeof execution.durationFrames !== "object" ||
      !Object.values(execution.durationFrames).every((count) => Number.isInteger(count) && count > 0)) {
    throw configurationError(`Video model '${catalog.id}' has an invalid duration map.`);
  }
  if (!Number.isInteger(execution.frameRate) || execution.frameRate < 1) {
    throw configurationError(`Video model '${catalog.id}' has an invalid frame rate.`);
  }
  for (const binding of ["prompt", "width", "height", "outputWidth", "outputHeight"]) {
    validateBinding(execution.bindings?.[binding], catalog.id, binding);
  }
  if (catalog.uiCapabilities.supportsFirstFrame === true) {
    if (typeof execution.workflows.firstFrame !== "string") {
      throw configurationError(`Video model '${catalog.id}' advertises a starting frame without a workflow.`);
    }
    validateBinding(execution.bindings?.inputImage, catalog.id, "inputImage");
  }
  for (const binding of ["frameCount", "frameRate"]) {
    const values = execution.bindings?.[binding];
    if (!Array.isArray(values) || values.length === 0) {
      throw configurationError(`Video model '${catalog.id}' has no '${binding}' bindings.`);
    }
    for (const value of values) validateBinding(value, catalog.id, binding);
  }
  if (execution.bindings?.seed) validateBinding(execution.bindings.seed, catalog.id, "seed");
}

function validateBinding(binding, modelID, name) {
  if (!binding || typeof binding.node !== "string" || typeof binding.input !== "string") {
    throw configurationError(`Model '${modelID}' has an invalid '${name}' binding.`);
  }
}

function validDimensions(value) {
  return Array.isArray(value) && value.length === 2 &&
    value.every((dimension) => Number.isInteger(dimension) && dimension > 0);
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

function setBindings(workflow, bindings, value, name) {
  for (const binding of bindings) setBinding(workflow, binding, value, name);
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
