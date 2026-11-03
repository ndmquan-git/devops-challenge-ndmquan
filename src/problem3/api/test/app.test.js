const test = require("node:test");
const assert = require("node:assert/strict");
const { createApp } = require("../src/app");

const silent = { error() {} };
const okDb = { query: async () => ({ rows: [{ now: "2026-01-01T00:00:00.000Z" }] }) };
const failingDb = {
  query: async () => {
    throw new Error("connection terminated unexpectedly");
  },
};
const okCache = { set: async () => "OK" };
const failingCache = {
  set: async () => {
    throw new Error("Stream isn't writeable");
  },
};

async function get(deps, path) {
  const server = createApp({ log: silent, ...deps }).listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
    return { status: res.status, body: await res.json() };
  } finally {
    server.closeAllConnections();
    server.close();
  }
}

test("GET /api/users returns the database time", async () => {
  const { status, body } = await get({ db: okDb, cache: okCache }, "/api/users");
  assert.equal(status, 200);
  assert.deepEqual(body, { ok: true, time: { now: "2026-01-01T00:00:00.000Z" } });
});

test("GET /api/users still succeeds when the cache is down", async () => {
  const { status, body } = await get({ db: okDb, cache: failingCache }, "/api/users");
  assert.equal(status, 200);
  assert.equal(body.ok, true);
});

test("GET /api/users returns 503 without exposing the database error", async () => {
  const { status, body } = await get({ db: failingDb, cache: okCache }, "/api/users");
  assert.equal(status, 503);
  assert.deepEqual(body, { ok: false, error: "database unavailable" });
});

test("GET /ready follows the database state", async () => {
  assert.equal((await get({ db: okDb, cache: okCache }, "/ready")).status, 200);
  assert.equal((await get({ db: failingDb, cache: okCache }, "/ready")).status, 503);
});
