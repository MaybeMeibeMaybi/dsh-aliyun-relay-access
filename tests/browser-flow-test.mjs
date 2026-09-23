// 严格模拟浏览器行为：只用网关下发的 cookie，不手工注入 dsh cookie。
// 这样才可能复现用户遇到的 "authentication required"。
//
// 用法：node browser-flow-test.mjs <baseUrl> <gatewayPassword> [dshToken]
//   dshToken 省略时，从本机 ~/.dsh/lan/web-state.json 读取（仅 Windows 侧适用）。
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

const BASE = process.argv[2] ?? "https://127.0.0.1:18443";
const PW = process.argv[3];
let TOKEN = process.argv[4];
if (!TOKEN) {
  const statePath = join(homedir(), ".dsh", "lan", "web-state.json");
  TOKEN = JSON.parse(readFileSync(statePath, "utf8").replace(/^\uFEFF/, "")).token;
}

/** 极简 cookie jar：按域名存，模拟浏览器 */
const jar = new Map();
function absorb(res) {
  const list = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
  for (const c of list) {
    const [pair] = c.split(";");
    const at = pair.indexOf("=");
    const name = pair.slice(0, at).trim();
    const value = pair.slice(at + 1).trim();
    if (value === "") jar.delete(name);
    else jar.set(name, value);
    console.log(`      [jar] set ${name}=${value.slice(0, 12)}...`);
  }
}
function cookieHeader() {
  return [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
}
async function go(path, init = {}) {
  const r = await fetch(BASE + path, { ...init, redirect: "manual", headers: { ...(init.headers ?? {}), cookie: cookieHeader() } });
  absorb(r);
  return r;
}

console.log("A 打开首页（未登录）");
let r = await go("/");
let t = await r.text();
console.log(`   HTTP ${r.status}  是登录页=${t.includes("请输入访问密码")}`);

console.log("B 提交密码");
r = await go("/__gw_login", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "password=" + encodeURIComponent(PW) });
t = await r.text();
console.log(`   HTTP ${r.status}  是 token 页=${t.includes("粘贴 dsh token")}`);

console.log("C 提交 dsh token");
r = await go("/__gw_token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "token=" + encodeURIComponent(TOKEN) });
console.log(`   HTTP ${r.status}  location=${r.headers.get("location") ?? "-"}`);

console.log("D 打开 GUI（只用浏览器手里的 cookie）");
r = await go("/");
t = await r.text();
const ok = /__DSH_BOOT__|id="root"/.test(t);
console.log(`   HTTP ${r.status}  字节=${t.length}  含应用标记=${ok}`);
if (!ok && t.length < 400) console.log("   响应片段: " + t.replace(/\s+/g, " ").slice(0, 200));

console.log("E 再打开一次（模拟刷新，验证会话持久）");
r = await go("/");
t = await r.text();
console.log(`   HTTP ${r.status}  字节=${t.length}  含应用标记=${/__DSH_BOOT__|id="root"/.test(t)}`);

console.log("F WebSocket 实时通道（/api/remote.mux）");
// 用内置 http/https 模块直接发 Upgrade 握手，不依赖 ws 库（服务器上没装）
const wsUrl = new URL(BASE);
const wsMod = wsUrl.protocol === "https:" ? await import("node:https") : await import("node:http");
await new Promise((resolve) => {
  const key = Buffer.from(Array.from({ length: 16 }, () => Math.floor(Math.random() * 256))).toString("base64");
  const req = wsMod.request({
    hostname: wsUrl.hostname,
    port: wsUrl.port || (wsUrl.protocol === "https:" ? 443 : 80),
    path: "/api/remote.mux",
    method: "GET",
    rejectUnauthorized: false,
    headers: {
      connection: "Upgrade",
      upgrade: "websocket",
      "sec-websocket-key": key,
      "sec-websocket-version": "13",
      cookie: cookieHeader()
    }
  });
  const timer = setTimeout(() => { console.log("   超时（未响应）"); try { req.destroy(); } catch {} resolve(); }, 8000);
  req.on("upgrade", (res, socket) => {
    clearTimeout(timer);
    console.log(`   HTTP ${res.statusCode}  ${res.statusCode === 101 ? "OPEN ✅ 实时通道已建立" : "非 101"}`);
    socket.destroy();
    resolve();
  });
  req.on("response", (res) => { clearTimeout(timer); console.log(`   被拒: HTTP ${res.statusCode}`); res.resume(); resolve(); });
  req.on("error", (e) => { clearTimeout(timer); console.log("   错误: " + e.message); resolve(); });
  req.end();
});
console.log("G 健康检查");
r = await go("/__gw_health");
console.log("   " + (await r.text()).trim());
