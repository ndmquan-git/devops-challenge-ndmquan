// Pool-leak proof. Runs inside the api image against the stack's Postgres:
//   docker compose run --rm --no-deps -v "$PWD/tests/pool-leak.js:/app/pool-leak.js:ro" api node /app/pool-leak.js
// (a) connect() plus a throwing query with no release() exhausts a pool of 2 after two failures;
// (b) pool.query() over the same failing query leaves the pool usable after ten failures.
const { Pool } = require("pg");

const config = {
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: 2,
  connectionTimeoutMillis: 1000,
};
const FAILING_QUERY = "SELECT 1/0";
let failed = false;

function check(ok, message) {
  console.log(`${ok ? "ok" : "not ok"} - ${message}`);
  if (!ok) failed = true;
}

async function leakingPattern(pool) {
  const client = await pool.connect();
  try {
    await client.query(FAILING_QUERY);
  } catch {
    // swallowed without client.release(), as the original handler did
  }
  return client;
}

async function main() {
  const leaky = new Pool(config);
  const leaked = [];
  for (let i = 0; i < config.max; i++) leaked.push(await leakingPattern(leaky));
  const started = Date.now();
  const outcome = await leaky.query("SELECT 1").then(() => "resolved", (err) => err.message);
  const elapsed = Date.now() - started;
  check(/timeout/i.test(outcome) && elapsed <= config.connectionTimeoutMillis + 500,
    `connect() without release: pool of ${config.max} exhausted after ${leaked.length} failed queries, SELECT 1 failed in ${elapsed} ms (${outcome})`);
  leaked.forEach((client) => client.release());
  await leaky.end();

  const safe = new Pool(config);
  let failures = 0;
  for (let i = 0; i < 10; i++) await safe.query(FAILING_QUERY).catch(() => failures++);
  const result = await safe.query("SELECT 1").then(() => "resolved", (err) => err.message);
  check(failures === 10 && result === "resolved", `pool.query(): ${failures} failed queries, SELECT 1 ${result}`);
  await safe.end();

  process.exitCode = failed ? 1 : 0;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
