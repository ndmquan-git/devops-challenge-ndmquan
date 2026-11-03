import test from "node:test";
import assert from "node:assert/strict";
import { statusLine } from "../src/status.js";

test("statusLine shows the API version", () => {
  assert.equal(statusLine("staging", "abc1234"), "staging: API abc1234");
});

test("statusLine reports an unreachable API", () => {
  assert.equal(statusLine("production", null), "production: API unreachable");
});
