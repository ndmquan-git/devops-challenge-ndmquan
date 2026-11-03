import { statusLine } from "./status.js";

const status = document.querySelector("#status");

async function main() {
  // Loaded at runtime so one build serves every environment.
  const config = await (await fetch("/config.json", { cache: "no-store" })).json();
  try {
    const res = await fetch(`${config.apiBaseUrl}/api/version`);
    const { version } = await res.json();
    status.textContent = statusLine(config.environment, version);
  } catch {
    status.textContent = statusLine(config.environment, null);
  }
}

main();
