const { Pool } = require("pg");
const Redis = require("ioredis");
const { createApp } = require("./app");

const port = Number(process.env.PORT || 3000);

const pool = new Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: Number(process.env.DB_POOL_MAX || 10),
  connectionTimeoutMillis: 2000,
  idleTimeoutMillis: 30000,
  // Both stay below nginx's 10 s proxy_read_timeout, so a stuck query fails the
  // request and frees its connection instead of holding it until nginx answers 504.
  statement_timeout: 5000,
  query_timeout: 5000,
});

// An idle client dropped by the server (restart, failover) emits here; without
// a listener Node treats it as an unhandled error and the process exits.
pool.on("error", (err) => console.error("postgres idle client error:", err.message));

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  enableOfflineQueue: false,
  maxRetriesPerRequest: 1,
  commandTimeout: 500,
});
redis.on("error", (err) => console.error("redis error:", err.message));

const server = createApp({ db: pool, cache: redis }).listen(port, () => {
  console.log(`API running on ${port}`);
});

function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  setTimeout(() => process.exit(1), 10000).unref();
  server.close(async () => {
    await Promise.allSettled([pool.end(), redis.quit()]);
    process.exit(0);
  });
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
