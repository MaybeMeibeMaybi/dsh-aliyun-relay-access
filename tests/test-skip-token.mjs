// 关键验证：浏览器只输密码，是否就能直接进入 GUI（无需粘贴 token）。
// 用法：set DSH_GW_PASSWORD=<网关密码> && node test-skip-token.mjs <baseUrl>
// 不要把密码写进源码——这个脚本会进公开仓库。
// 严格模拟浏览器：cookie jar + 跟随重定向。
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

const BASE = "https://203.0.113.10:18443";
const PW = process.env.DSH_GW_PASSWORD ?? "";

const jar = new Map();
function absorb(res) {
  for (const c of res.headers.getSetCookie ? res.headers.getSetCookie() : []) {
    const [pair] = c.split(";");
    const at = pair.indexOf("=");
    const name = pair.slice(0, at).trim();
    const value = pair.slice(at + 1).trim();
    if (value === "") jar.delete(name);
    else jar.set(name, value);
  }
}
const cookieHeader = () => [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
const hasAppMarkup = (t) => t.includes("__DSH_BOOT__") || t.includes('id="root"');

async function go(path, init = {}) {
  const r = await fetch(BASE + path, { ...init, redirect: "manual", headers: { ...(init.headers ?? {}), cookie: cookieHeader() } });
  absorb(r);
  return r;
}

// A) 首次访问：应是登录页
let r = await go("/");
let t = await r.text();
console.log(`A 首次访问      : HTTP ${r.status}  登录页=${t.includes("请输入访问密码")}`);

// B) 只输入密码（不提供任何 token）
r = await go("/__gw_login", {
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded" },
  body: "password=" + encodeURIComponent(PW)
});
const loc = r.headers.get("location");
t = await r.text();
if (loc === "/") {
  console.log(`B 只输密码      : HTTP ${r.status}  location=/  ✅ 直接进 GUI，无需粘贴 token`);
} else {
  console.log(`B 只输密码      : HTTP ${r.status}  location=${loc ?? "(无)"}  ⚠️ 仍要求粘贴 token`);
  console.log(`   页面提示: ${t.replace(/\s+/g, " ").match(/<p>([^<]{5,80})<\/p>/)?.[1] ?? "(未识别)"}`);
}

// C) 打开 GUI
r = await go("/");
t = await r.text();
console.log(`C 打开 GUI      : HTTP ${r.status}  字节=${t.length}  含应用标记=${hasAppMarkup(t)}`);

// D) 刷新一次，确认会话持久
r = await go("/");
t = await r.text();
console.log(`D 刷新          : HTTP ${r.status}  字节=${t.length}  含应用标记=${hasAppMarkup(t)}`);

// E) WebSocket 实时通道（纯内置模块握手）
const wsUrl = new URL(BASE);
const wsMod = await import("node:https");
await new Promise((resolve) => {
  const key = Buffer.from(Array.from({ length: 16 }, () => Math.floor(Math.random() * 256))).toString("base64");
  const req = wsMod.request({
    hostname: wsUrl.hostname,
    port: wsUrl.port,
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
  const timer = setTimeout(() => { console.log("E WebSocket     : 超时"); try { req.destroy(); } catch {} resolve(); }, 8000);
  req.on("upgrade", (res, socket) => {
    clearTimeout(timer);
    console.log(`E WebSocket     : HTTP ${res.statusCode}  ${res.statusCode === 101 ? "OPEN ✅" : "非 101"}`);
    socket.destroy();
    resolve();
  });
  req.on("response", (res) => { clearTimeout(timer); console.log(`E WebSocket     : 被拒 HTTP ${res.statusCode}`); res.resume(); resolve(); });
  req.on("error", (e) => { clearTimeout(timer); console.log(`E WebSocket     : 错误 ${e.message}`); resolve(); });
  req.end();
});
