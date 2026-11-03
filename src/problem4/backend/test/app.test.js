const test = require("node:test");
const assert = require("node:assert/strict");
const { createApp } = require("../src/app");

async function get(options, path) {
  const server = createApp(options).listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
    return { status: res.status, headers: res.headers, body: await res.json() };
  } finally {
    server.closeAllConnections();
    server.close();
  }
}

test("GET /healthz reports ok", async () => {
  const { status, body } = await get({}, "/healthz");
  assert.equal(status, 200);
  assert.deepEqual(body, { status: "ok" });
});

test("GET /api/version returns the deployed version", async () => {
  const { body } = await get({ version: "abc1234" }, "/api/version");
  assert.deepEqual(body, { version: "abc1234" });
});

test("GET /api/items lists items", async () => {
  const { body } = await get({}, "/api/items");
  assert.equal(body.items.length, 2);
});

test("CORS header is set only when an origin is configured", async () => {
  const open = await get({}, "/healthz");
  assert.equal(open.headers.get("access-control-allow-origin"), null);
  const scoped = await get({ allowedOrigin: "https://app.example.com" }, "/healthz");
  assert.equal(scoped.headers.get("access-control-allow-origin"), "https://app.example.com");
});
