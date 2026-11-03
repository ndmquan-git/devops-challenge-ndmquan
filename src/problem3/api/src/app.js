const express = require("express");

function createApp({ db, cache, log = console }) {
  const app = express();

  app.get("/api/users", async (req, res) => {
    let time;
    try {
      const result = await db.query("SELECT NOW()");
      time = result.rows[0];
    } catch (err) {
      log.error("database query failed:", err.message);
      return res.status(503).json({ ok: false, error: "database unavailable" });
    }

    // The cache only records the last call, so a Redis outage must not fail the request.
    cache.set("last_call", Date.now()).catch((err) => log.error("cache write failed:", err.message));

    res.json({ ok: true, time });
  });

  app.get("/status", (req, res) => {
    res.json({ status: "ok" });
  });

  app.get("/ready", async (req, res) => {
    try {
      await db.query("SELECT 1");
      res.json({ status: "ready" });
    } catch {
      res.status(503).json({ status: "unavailable" });
    }
  });

  return app;
}

module.exports = { createApp };
