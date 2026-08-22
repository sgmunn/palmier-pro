#!/usr/bin/env node

import process from "node:process";
import readline from "node:readline/promises";

const defaults = {
  url: "http://127.0.0.1:19789/mcp",
  prompt: "A cinematic documentary still of a lighthouse in sea mist at sunrise",
  aspectRatio: "16:9",
  timeoutSeconds: 120,
  pollSeconds: 1,
};

function usage() {
  console.log(`Usage: node scripts/mcp/test-custom-image.mjs [options]

Options:
  --yes                  Make the paid generation request without prompting
  --check                 Verify MCP, project, and model setup without generating
  --prompt <text>        Image prompt
  --name <text>          Media-library asset name
  --aspect-ratio <ratio> Aspect ratio (default: ${defaults.aspectRatio})
  --project-path <path>  Open and bind this .palmier project for the MCP session
  --project-name <name>  Open and bind a known project by name
  --url <url>            MCP endpoint (default: ${defaults.url})
  --timeout <seconds>    Poll timeout (default: ${defaults.timeoutSeconds})
  --poll <seconds>       Poll interval (default: ${defaults.pollSeconds})
  --help                 Show this help

Palmier Pro must be running with MCP enabled. Configure Custom Gateway in the app
before running this test. The Together API key remains in the app's Keychain.`);
}

function parseArguments(argv) {
  const options = { ...defaults, yes: false, check: false };
  const values = new Set([
    "--prompt", "--name", "--aspect-ratio", "--project-path", "--project-name",
    "--url", "--timeout", "--poll",
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help") {
      usage();
      process.exit(0);
    }
    if (argument === "--yes") {
      options.yes = true;
      continue;
    }
    if (argument === "--check") {
      options.check = true;
      continue;
    }
    if (!values.has(argument)) {
      throw new Error(`Unknown option: ${argument}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${argument}`);
    }
    index += 1;
    switch (argument) {
    case "--prompt": options.prompt = value; break;
    case "--name": options.name = value; break;
    case "--aspect-ratio": options.aspectRatio = value; break;
    case "--project-path": options.projectPath = value; break;
    case "--project-name": options.projectName = value; break;
    case "--url": options.url = value; break;
    case "--timeout": options.timeoutSeconds = Number(value); break;
    case "--poll": options.pollSeconds = Number(value); break;
    }
  }

  if (options.projectPath && options.projectName) {
    throw new Error("Use only one of --project-path or --project-name.");
  }
  if (!Number.isFinite(options.timeoutSeconds) || options.timeoutSeconds <= 0) {
    throw new Error("--timeout must be a positive number.");
  }
  if (!Number.isFinite(options.pollSeconds) || options.pollSeconds <= 0) {
    throw new Error("--poll must be a positive number.");
  }
  options.name ??= `MCP Together test ${new Date().toISOString()}`;
  return options;
}

function parseEventStream(body, expectedID) {
  const messages = body.split(/\r?\n\r?\n/).flatMap((event) => {
    const data = event.split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trim())
      .join("\n");
    if (!data) return [];
    try { return [JSON.parse(data)]; } catch { return []; }
  });
  return messages.find((message) => message.id === expectedID) ?? messages.at(-1);
}

class MCPClient {
  constructor(url) {
    this.url = url;
    this.nextID = 1;
    this.sessionID = undefined;
    this.protocolVersion = "2025-03-26";
  }

  async send(message) {
    const headers = {
      Accept: "application/json, text/event-stream",
      "Content-Type": "application/json",
      Origin: new URL(this.url).origin,
    };
    if (this.sessionID) headers["Mcp-Session-Id"] = this.sessionID;
    if (this.sessionID) headers["MCP-Protocol-Version"] = this.protocolVersion;

    let response;
    try {
      response = await fetch(this.url, {
        method: "POST",
        headers,
        body: JSON.stringify(message),
      });
    } catch (error) {
      throw new Error(`Cannot connect to ${this.url}. Is Palmier Pro running with MCP enabled?\n${error.message}`);
    }

    const assignedSession = response.headers.get("mcp-session-id");
    if (assignedSession) this.sessionID = assignedSession;
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`MCP HTTP ${response.status}: ${body.slice(0, 1_000) || response.statusText}`);
    }
    if (!body.trim()) return undefined;
    const contentType = response.headers.get("content-type") ?? "";
    const envelope = contentType.includes("text/event-stream")
      ? parseEventStream(body, message.id)
      : JSON.parse(body);
    if (envelope?.error) {
      throw new Error(`MCP ${envelope.error.code}: ${envelope.error.message}`);
    }
    return envelope?.result;
  }

  async request(method, params = {}) {
    const id = this.nextID;
    this.nextID += 1;
    return this.send({ jsonrpc: "2.0", id, method, params });
  }

  async notify(method, params = {}) {
    await this.send({ jsonrpc: "2.0", method, params });
  }

  async initialize() {
    const result = await this.request("initialize", {
      protocolVersion: this.protocolVersion,
      capabilities: {},
      clientInfo: { name: "palmier-custom-image-test", version: "1.0.0" },
    });
    this.protocolVersion = result.protocolVersion;
    await this.notify("notifications/initialized");
    return result;
  }

  async callTool(name, argumentsValue = {}) {
    const result = await this.request("tools/call", { name, arguments: argumentsValue });
    const text = (result.content ?? [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");
    if (result.isError) throw new Error(`${name}: ${text || "Tool failed"}`);
    return { result, text };
  }
}

function parseJSONToolText(toolName, text) {
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${toolName} returned invalid JSON: ${text.slice(0, 500)}`);
  }
}

function sleep(seconds) {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1_000));
}

async function confirmPaidRequest(options) {
  if (options.yes) return;
  if (!process.stdin.isTTY) {
    throw new Error("Refusing to make a paid generation request without --yes in a non-interactive shell.");
  }
  const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await prompt.question("This will make one billable request through your custom gateway. Continue? [y/N] ");
  prompt.close();
  if (!/^y(es)?$/i.test(answer.trim())) process.exit(0);
}

async function run() {
  const options = parseArguments(process.argv.slice(2));
  const client = new MCPClient(options.url);

  const initialized = await client.initialize();
  console.log(`Connected to ${initialized.serverInfo.name} using MCP ${initialized.protocolVersion}.`);

  const listed = await client.request("tools/list");
  const toolNames = new Set(listed.tools.map((tool) => tool.name));
  for (const required of ["manage_project", "list_models", "generate_image", "get_media", "inspect_media"]) {
    if (!toolNames.has(required)) throw new Error(`Palmier MCP server does not expose required tool: ${required}`);
  }
  console.log("Required MCP tools are available.");

  if (options.projectPath || options.projectName) {
    const target = options.projectPath ? { path: options.projectPath } : { name: options.projectName };
    const opened = await client.callTool("manage_project", { action: "open", ...target });
    console.log(opened.text);
  } else {
    const projects = await client.callTool("manage_project", { action: "list" });
    console.log(projects.text);
  }

  const models = await client.callTool("list_models", { type: "image" });
  const modelPayload = parseJSONToolText("list_models", models.text);
  const customModel = modelPayload.models?.find((model) => model.id === "custom/image/default");
  if (!customModel) {
    throw new Error("Custom image model is unavailable. Select Custom Gateway in Palmier Settings and wait for models to load.");
  }
  console.log("Custom image catalog is loaded.");

  if (options.check) {
    console.log("PASS: MCP connection, tool discovery, project binding, and custom image catalog are ready.");
    return;
  }

  await confirmPaidRequest(options);
  const submitted = await client.callTool("generate_image", {
    prompt: options.prompt,
    name: options.name,
    model: "custom/image/default",
    aspectRatio: options.aspectRatio,
  });
  console.log(submitted.text);

  const match = submitted.text.match(/Placeholder asset ID:\s*([^\s.]+)/);
  if (!match) throw new Error("Could not read the placeholder asset ID from generate_image.");
  const mediaRef = match[1];
  const deadline = Date.now() + options.timeoutSeconds * 1_000;

  while (Date.now() < deadline) {
    const media = await client.callTool("get_media", { ids: [mediaRef] });
    const payload = parseJSONToolText("get_media", media.text);
    const asset = payload.assets?.find((candidate) => candidate.id === mediaRef);
    if (!asset) throw new Error(`Placeholder ${mediaRef} disappeared from the media library.`);
    if (!asset.generationStatus) {
      const inspected = await client.callTool("inspect_media", { mediaRef });
      const image = inspected.result.content?.find((block) => block.type === "image");
      if (!image || !image.mimeType?.startsWith("image/")) {
        throw new Error("Asset became ready but inspect_media did not return an image.");
      }
      console.log(`PASS: ${mediaRef} is ready and inspect_media read back ${image.mimeType} through MCP.`);
      return;
    }
    if (asset.generationStatus.startsWith("failed")) {
      throw new Error(`Generation failed: ${asset.generationStatus}`);
    }
    console.log(`Waiting for ${mediaRef}: ${asset.generationStatus}`);
    await sleep(options.pollSeconds);
  }

  throw new Error(`Timed out after ${options.timeoutSeconds}s while waiting for ${mediaRef}.`);
}

run().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
});
