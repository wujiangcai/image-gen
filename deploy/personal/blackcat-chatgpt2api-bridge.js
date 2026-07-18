#!/usr/bin/env node
"use strict";

/**
 * blackcat-relogin-dev → chatgpt2api-bk 账号同步桥接
 * ====================================================
 * 读取 blackcat 保存的 codex JSON，把 access_token 推送到 chatgpt2api 账号池。
 * 刷新时：先删除该邮箱上次导入的旧 access_token，再导入新 access_token，避免重复账号。
 *
 * 用法：
 *   node blackcat-chatgpt2api-bridge.js \
 *     --save-dir "C:/.../blackcat-relogin-dev/codex_relogin" \
 *     --base-url http://127.0.0.1:8001 \
 *     --auth-key chatgpt2api \
 *     [--state-file ./bridge-state.json] \
 *     [--dry-run]
 *
 * 说明：
 *   - chatgpt2api 的账号以 access_token 为唯一键。
 *   - blackcat refresh 后 access_token 会变（新 JWT），直接再导入会产生重复账号，
 *     所以本脚本维护 email -> 上次导入 token 的映射，刷新时先 DELETE 旧再加新。
 *   - chatgpt2api 导入后自动调用 /backend-api/me 补齐 email / 类型 / 图像额度。
 */

const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      const next = argv[i + 1];
      if (!next || next.startsWith("--")) args[key] = true;
      else args[key] = argv[++i];
    } else {
      args._.push(a);
    }
  }
  return args;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

// 读取 blackcat saveDir 下所有含 access_token 的 JSON
function findBlackcatTokens(saveDir) {
  if (!fs.existsSync(saveDir)) return [];
  const out = [];
  for (const name of fs.readdirSync(saveDir)) {
    if (!name.toLowerCase().endsWith(".json")) continue;
    const file = path.join(saveDir, name);
    if (!fs.statSync(file).isFile()) continue;
    const data = readJson(file);
    if (!data || !data.access_token) continue;
    const email = String(data.email || "").trim().toLowerCase();
    out.push({
      file: name,
      email,
      access_token: String(data.access_token).trim(),
      session_token: String(data.session_token || "").trim(),
      workspace_id: data.workspace_id || data.account_id || "",
      source: data.source || ""
    });
  }
  return out;
}

function requestJson({ baseUrl, apiPath, method, authKey, body }) {
  return new Promise((resolve, reject) => {
    const u = new URL(apiPath, baseUrl);
    const payload = body ? JSON.stringify(body) : null;
    const lib = u.protocol === "https:" ? https : http;
    const headers = {
      "Content-Type": "application/json",
      Accept: "application/json"
    };
    if (authKey) headers["Authorization"] = /^Bearer\s/i.test(authKey) ? authKey : `Bearer ${authKey}`;
    if (payload) headers["Content-Length"] = Buffer.byteLength(payload);
    const req = lib.request(
      u,
      { method, headers, timeout: 30000 },
      (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => {
          let json = null;
          try {
            json = buf ? JSON.parse(buf) : null;
          } catch {
            /* keep null */
          }
          resolve({ status: res.statusCode, json, text: buf });
        });
      }
    );
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.saveDir) {
    console.log(`
blackcat → chatgpt2api 账号同步桥接

必填:
  --save-dir <dir>        blackcat 保存 JSON 的目录 (codex_relogin)
  --base-url <url>        chatgpt2api 地址, 默认 http://127.0.0.1:8001
  --auth-key <key>        chatgpt2api 管理员 key (CHATGPT2API_AUTH_KEY)

可选:
  --state-file <file>     记录 email->上次导入 token 的映射文件
  --dry-run               只打印将要做什么, 不实际请求 chatgpt2api
`);
    return;
  }

  const baseUrl = (args.baseUrl || "http://127.0.0.1:8001").replace(/\/$/, "");
  const authKey = args.authKey || "";
  const stateFile = args.stateFile || path.join(process.cwd(), "bridge-state.json");
  const dryRun = !!args.dryRun;

  const tokens = findBlackcatTokens(path.resolve(args.saveDir));
  if (!tokens.length) {
    console.log(`[bridge] saveDir 下没有可用的 access_token JSON: ${args.saveDir}`);
    return;
  }

  // 按 email 归并：同一邮箱保留最新（文件按名排序，后写的覆盖）；没有 email 的用 access_token 前 12 位做键
  const byKey = new Map();
  for (const t of tokens) {
    const key = t.email || `at:${t.access_token.slice(0, 12)}`;
    byKey.set(key, t); // 后出现的覆盖，等价于"最新"
  }

  let state = {};
  if (fs.existsSync(stateFile)) state = readJson(stateFile) || {};

  // 计算要删除的旧 token（同一 email 上次导入的、且和当前不同的）
  const toAdd = [];
  const toDelete = [];
  const newState = {};
  for (const [key, t] of byKey) {
    const prev = state[key];
    if (prev && prev !== t.access_token) {
      toDelete.push(prev);
    }
    toAdd.push(t.access_token);
    newState[key] = t.access_token;
  }

  console.log(`[bridge] 扫描到 ${tokens.length} 个 JSON, 去重后 ${byKey.size} 个账号`);
  for (const [key, t] of byKey) {
    const changed = state[key] !== t.access_token;
    console.log(
      `  - ${key || "(无email)"} | ${t.source || "workspace"} | ${t.workspace_id.slice(0, 8) || "-"} | ${changed ? "有变更" : "无变更"}`
    );
  }

  if (dryRun) {
    console.log(`[bridge] DRY-RUN, 不实际请求。`);
    console.log(`  将导入 ${toAdd.length} 个 token, 将删除 ${toDelete.length} 个旧 token`);
    return;
  }

  if (toDelete.length) {
    const r = await requestJson({
      baseUrl,
      apiPath: "/api/accounts",
      method: "DELETE",
      authKey,
      body: { tokens: toDelete }
    });
    console.log(`[bridge] DELETE 旧 token: HTTP ${r.status} -> ${r.text.slice(0, 200)}`);
    if (r.status < 200 || r.status >= 300) {
      throw new Error(`DELETE 旧 token 失败: HTTP ${r.status}`);
    }
  }

  if (toAdd.length) {
    const r = await requestJson({
      baseUrl,
      apiPath: "/api/accounts",
      method: "POST",
      authKey,
      body: { tokens: toAdd }
    });
    console.log(`[bridge] POST 导入: HTTP ${r.status}`);
    if (r.status < 200 || r.status >= 300) {
      throw new Error(`POST 导入失败: HTTP ${r.status} ${r.text.slice(0, 200)}`);
    }
    if (r.json) {
      const added = r.json.added ?? "?";
      const refreshed = r.json.refreshed ?? "?";
      const errCount = Array.isArray(r.json.errors) ? r.json.errors.length : 0;
      console.log(`  added=${added} refreshed=${refreshed} errors=${errCount}`);
      if (errCount) console.log("  错误样例:", JSON.stringify(r.json.errors.slice(0, 3)));
    } else {
      console.log(`  ${r.text.slice(0, 200)}`);
    }
  }

  fs.writeFileSync(stateFile, JSON.stringify(newState, null, 2), "utf8");
  console.log(`[bridge] 已更新状态文件: ${stateFile}`);
  console.log(`[bridge] done.`);
}

if (require.main === module) {
  main().catch((e) => {
    console.error("[bridge] error:", e.stack || e.message);
    process.exit(1);
  });
}

module.exports = { findBlackcatTokens, main, parseArgs, requestJson };
