const { test } = require("node:test");
const assert = require("node:assert/strict");
const request = require("supertest");

const { app } = require("../src/app");

test("GET /project/status returns module completion report", async () => {
  const res = await request(app).get("/project/status");
  assert.equal(res.status, 200);
  assert.equal(res.body.success, true);
  assert.equal(typeof res.body.completionPercent, "number");
  assert.equal(Array.isArray(res.body.modules), true);
  assert.ok(res.body.modules.length >= 5);
});

test("GET /project/synopsis-alignment returns section-wise mapping", async () => {
  const res = await request(app).get("/project/synopsis-alignment");
  assert.equal(res.status, 200);
  assert.equal(res.body.success, true);
  assert.equal(typeof res.body.overallCompletionPercent, "number");
  assert.equal(Array.isArray(res.body.sections), true);
  assert.ok(res.body.sections.length >= 5);
  assert.equal(Array.isArray(res.body.remainingHighPriority), true);
});
