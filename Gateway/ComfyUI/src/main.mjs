import { pathToFileURL } from "node:url";
import { ComfyClient } from "./comfy-client.mjs";
import { ModelRegistry } from "./model-registry.mjs";
import { createGatewayServer } from "./server.mjs";

const apiKey = process.env.PALMIER_GATEWAY_API_KEY;
if (!apiKey) throw new Error("Set PALMIER_GATEWAY_API_KEY before starting the gateway.");

const host = process.env.PALMIER_GATEWAY_HOST ?? "127.0.0.1";
const port = parsePort(process.env.PALMIER_GATEWAY_PORT ?? "8190");
const comfyURL = process.env.PALMIER_COMFY_URL ?? "http://127.0.0.1:8188";
const timeoutMilliseconds = parsePositiveInteger(
  process.env.PALMIER_COMFY_TIMEOUT_MS ?? String(15 * 60 * 1000),
  "PALMIER_COMFY_TIMEOUT_MS"
);
const modelsDirectoryURL = process.env.PALMIER_GATEWAY_MODELS_DIR
  ? pathToFileURL(process.env.PALMIER_GATEWAY_MODELS_DIR)
  : new URL("../models/", import.meta.url);

const server = await createGatewayServer({
  apiKey,
  comfyClient: new ComfyClient({ baseURL: comfyURL, timeoutMilliseconds }),
  modelRegistry: new ModelRegistry({ modelsDirectoryURL }),
});

server.listen(port, host, () => {
  process.stdout.write(`Palmier ComfyUI gateway listening at http://${host}:${port}\n`);
});

function parsePort(value) {
  const port = parsePositiveInteger(value, "PALMIER_GATEWAY_PORT");
  if (port > 65535) throw new Error("PALMIER_GATEWAY_PORT must not exceed 65535.");
  return port;
}

function parsePositiveInteger(value, name) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1) throw new Error(`${name} must be a positive integer.`);
  return number;
}
