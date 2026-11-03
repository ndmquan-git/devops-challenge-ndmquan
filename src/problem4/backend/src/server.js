const { createApp } = require("./app");

const port = Number(process.env.PORT || 3000);

const server = createApp({
  version: process.env.APP_VERSION,
  allowedOrigin: process.env.ALLOWED_ORIGIN,
}).listen(port, () => {
  console.log(`backend listening on ${port}`);
});

function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  setTimeout(() => process.exit(1), 10000).unref();
  server.close(() => process.exit(0));
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
