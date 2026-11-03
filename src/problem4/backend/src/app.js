const express = require("express");

const items = [
  { id: 1, name: "alpha" },
  { id: 2, name: "beta" },
];

function createApp({ version = "dev", allowedOrigin = "" } = {}) {
  const app = express();
  app.disable("x-powered-by");

  if (allowedOrigin) {
    app.use((req, res, next) => {
      res.set("Access-Control-Allow-Origin", allowedOrigin);
      res.set("Vary", "Origin");
      next();
    });
  }

  app.get("/healthz", (req, res) => {
    res.json({ status: "ok" });
  });

  app.get("/api/version", (req, res) => {
    res.json({ version });
  });

  app.get("/api/items", (req, res) => {
    res.json({ items });
  });

  return app;
}

module.exports = { createApp };
