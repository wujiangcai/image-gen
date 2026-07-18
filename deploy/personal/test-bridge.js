"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");

const { findBlackcatTokens, parseArgs, requestJson } = require("./blackcat-chatgpt2api-bridge");

test("kebab-case CLI 参数会转换成 camelCase", () => {
  const args = parseArgs(["--save-dir", "./tokens", "--base-url", "http://127.0.0.1", "--dry-run"]);
  assert.equal(args.saveDir, "./tokens");
  assert.equal(args.baseUrl, "http://127.0.0.1");
  assert.equal(args.dryRun, true);
});

test("只读取包含 access_token 的 Blackcat JSON", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-test-"));
  try {
    fs.writeFileSync(path.join(dir, "valid.json"), JSON.stringify({ email: "USER@example.com", access_token: "token-value" }));
    fs.writeFileSync(path.join(dir, "invalid.json"), JSON.stringify({ email: "ignored@example.com" }));
    const items = findBlackcatTokens(dir);
    assert.equal(items.length, 1);
    assert.equal(items[0].email, "user@example.com");
    assert.equal(items[0].access_token, "token-value");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("后台请求自动添加 Bearer 前缀并解析 JSON", async () => {
  let receivedAuthorization = "";
  const server = http.createServer((req, res) => {
    receivedAuthorization = req.headers.authorization || "";
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    const result = await requestJson({
      baseUrl: `http://127.0.0.1:${address.port}`,
      apiPath: "/api/accounts",
      method: "POST",
      authKey: "admin-key",
      body: { tokens: ["test-token"] }
    });
    assert.equal(result.status, 200);
    assert.deepEqual(result.json, { ok: true });
    assert.equal(receivedAuthorization, "Bearer admin-key");
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
