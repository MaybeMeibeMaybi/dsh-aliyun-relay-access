/**
 * dsh-auth-gateway.mjs - 给 dsh GUI 加一层"HTTPS + 密码"入口，手机无需任何客户端。
 *
 * 为什么需要它：原生鸿蒙没有可用的 SSH 客户端，SSH 隧道方案在原生环境下走不通。
 * 本网关把"加密 + 认证"搬到服务器侧，手机只要浏览器就能安全访问。
 *
 * ── 会话模型（关键设计）────────────────────────────────────────────────
 * dsh 的会话 cookie **按 authority 命名**（cookieName = 前缀 + sha256(authority)），
 * 而网关会把 Host 改写成 127.0.0.1:<backendPort>。于是：
 *
 *   错误做法：把 dsh 的 set-cookie 原样透传给浏览器。
 *             → cookie 名字是给 127.0.0.1 的，浏览器存在公网 IP 名下，后续带不回去，
 *               表现为"第一次进入提示 authentication required"。
 *
 *   正确做法：**网关持有 dsh 会话，浏览器只持有网关会话**。
 *     1. 浏览器用密码换网关会话（HMAC 签名的 cookie）
 *     2. 网关用 dsh token 在内部换取 dsh 会话 cookie 并保存
 *     3. 后续请求由网关注入 dsh cookie，同时剥掉上游的 set-cookie
 *
 * ── token 从哪里来（两种，且都无需用户手工粘贴）────────────────────────
 *   A. 电脑上的 dsh-token-broadcast 插件在 dsh 启动时，用**注册密钥**把 token
 *      上报给本网关的 /__gw_register。密钥只在服务器与电脑之间传递，不经浏览器。
 *   B. 兜底：用户在浏览器里手工粘贴一次 token。
 *
 * dsh 重启会让旧 token 失效，网关检测到后会**静默用最新 token 重建会话**，
 * 用户不必重新登录（除非新 token 还没上报）。
 *
 * ── 其它关键点 ─────────────────────────────────────────────────────────
 *   - 转发时去掉 Origin：dsh 的 /api 围栏只在该头存在时要求它与 Host 一致
 *   - 隧道 WebSocket 升级（/api/remote.mux），否则会话列表为空、一直"自动重连中"
 *   - 密码只以 scrypt 派生值保存；登录失败按 IP 节流
 *
 * 用法：
 *   node dsh-auth-gateway.mjs --port 18443 --cert cert.pem --key key.pem \
 *        [--password 明文 | --password-hash scrypt十六进制] [--backend-port 18080] \
 *        [--register-key-file /run/dsh-gw/register-key]
 *   密码/密钥也可用环境变量 DSH_GW_PASSWORD / DSH_GW_REGISTER_KEY。
 */

import http from "node:http";
import https from "node:https";
import { readFileSync, existsSync } from "node:fs";
import { createHmac, randomBytes, scryptSync, timingSafeEqual } from "node:crypto";

// ------------------------------------------------------------------ 参数
function arg(name, fallback) {
	const i = process.argv.indexOf(`--${name}`);
	return i !== -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}

const BIND_IP = arg("bind-ip", "127.0.0.1");
const PORT = Number(arg("port", "18443"));
const BACKEND_HOST = arg("backend-host", "127.0.0.1");
const BACKEND_PORT = Number(arg("backend-port", "18080"));
const CERT = arg("cert", "");
const KEY = arg("key", "");
const PFX = arg("pfx", "");
const PFX_PASS = arg("pfx-pass", "");
const PASSWORD = arg("password", process.env.DSH_GW_PASSWORD ?? "");
const PASSWORD_HASH = arg("password-hash", process.env.DSH_GW_PASSWORD_HASH ?? "");
const REGISTER_KEY_FILE = arg("register-key-file", process.env.DSH_GW_REGISTER_KEY_FILE ?? "");
const REGISTER_KEY_INLINE = arg("register-key", process.env.DSH_GW_REGISTER_KEY ?? "");
const SESSION_HOURS = Number(arg("session-hours", "12"));
const MAX_CONTENT = 8000;

const COOKIE_NAME = "dsh_gw";
const SALT = "dsh-gateway-v1";
const TOKEN_SALT = "dsh-gateway-token-v1";

function tlsOptions() {
	if (PFX) {
		if (!existsSync(PFX)) throw new Error(`--pfx 不存在: ${PFX}`);
		return { pfx: readFileSync(PFX), passphrase: PFX_PASS || undefined };
	}
	if (!CERT || !KEY || !existsSync(CERT) || !existsSync(KEY)) {
		throw new Error("需要 --pfx，或 --cert 与 --key（文件必须存在）");
	}
	return { cert: readFileSync(CERT), key: readFileSync(KEY) };
}

let TLS_OPTIONS;
try {
	TLS_OPTIONS = tlsOptions();
} catch (error) {
	console.error(`[gateway] ${error.message}`);
	console.error('[gateway] Linux 生成自签证书：openssl req -x509 -newkey rsa:2048 -nodes -days 825 -keyout key.pem -out cert.pem -subj "/CN=<IP或域名>" -addext "subjectAltName=IP:<IP>"');
	process.exit(1);
}
if (!PASSWORD && !PASSWORD_HASH) {
	console.error("[gateway] 需要 --password 或 --password-hash（拒绝无密码启动）");
	process.exit(1);
}

const expectedHash = PASSWORD_HASH ? Buffer.from(PASSWORD_HASH, "hex") : scryptSync(PASSWORD, SALT, 32);
function passwordOk(candidate) {
	if (typeof candidate !== "string" || candidate.length === 0) return false;
	const got = scryptSync(candidate, SALT, 32);
	return got.length === expectedHash.length && timingSafeEqual(got, expectedHash);
}

/** 注册密钥：用于让电脑上的插件上报 token。优先读文件（不进环境变量，避免被同机用户读取）。 */
function loadRegisterKey() {
	if (REGISTER_KEY_INLINE) return REGISTER_KEY_INLINE.trim();
	if (REGISTER_KEY_FILE && existsSync(REGISTER_KEY_FILE)) {
		try {
			return readFileSync(REGISTER_KEY_FILE, "utf8").trim();
		} catch {
			return "";
		}
	}
	return "";
}
let registerKey = loadRegisterKey();
function registerKeyOk(candidate) {
	if (!registerKey || typeof candidate !== "string" || candidate.length === 0) return false;
	const a = Buffer.from(candidate);
	const b = Buffer.from(registerKey);
	return a.length === b.length && timingSafeEqual(a, b);
}

/** 签名密钥：每次启动随机生成，重启即让所有浏览器会话失效（需要重新输密码）。 */
const SIGNING_KEY = randomBytes(32);
function signSession(payload) {
	const body = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
	const sig = createHmac("sha256", SIGNING_KEY).update(body).digest("base64url");
	return `${body}.${sig}`;
}
function verifySession(value) {
	if (typeof value !== "string") return undefined;
	const [body, sig] = value.split(".");
	if (!body || !sig) return undefined;
	const wanted = createHmac("sha256", SIGNING_KEY).update(body).digest("base64url");
	const a = Buffer.from(sig);
	const b = Buffer.from(wanted);
	if (a.length !== b.length || !timingSafeEqual(a, b)) return undefined;
	try {
		const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
		if (typeof payload.exp !== "number" || payload.exp < Date.now()) return undefined;
		return payload;
	} catch {
		return undefined;
	}
}
function cookieValue(header, name) {
	if (!header) return undefined;
	for (const seg of header.split(";")) {
		const at = seg.indexOf("=");
		if (at === -1) continue;
		if (seg.slice(0, at).trim() === name) return seg.slice(at + 1).trim();
	}
	return undefined;
}

// ------------------------------------------------------------ token 存储
/**
 * 当前生效的 dsh token 与对应会话 cookie。
 * token 只存进程内存：网关重启后需要等插件重新上报（或用户手工粘贴一次）。
 */
const tokenState = { token: "", dshCookie: "", source: "", at: 0 };

// ------------------------------------------------ 客户端会话（浏览器侧）
/** sessionId -> { dshCookie, ip, exp, forToken } */
const clientSessions = new Map();

function newSessionId() {
	return randomBytes(24).toString("base64url");
}
function putSession(id, dshCookie, ip) {
	clientSessions.set(id, { dshCookie, ip, exp: Date.now() + SESSION_HOURS * 3600_000, forToken: tokenState.token });
}
function getSession(id) {
	if (!id) return undefined;
	const rec = clientSessions.get(id);
	if (!rec) return undefined;
	if (rec.exp < Date.now()) {
		clientSessions.delete(id);
		return undefined;
	}
	return rec;
}
function dropSession(id) {
	if (id) clientSessions.delete(id);
}
setInterval(() => {
	const now = Date.now();
	for (const [id, rec] of clientSessions) if (rec.exp < now) clientSessions.delete(id);
}, 60_000).unref();

/** 判断一个 set-cookie 是不是 dsh 的会话 cookie（名字以固定前缀开头、值是 v1. 签名串）。 */
function isDshSessionCookie(setCookie) {
	return /^[A-Za-z0-9_-]+=v1\./i.test(String(setCookie).trim());
}
function extractDshCookie(headers) {
	const raw = headers["set-cookie"];
	if (!raw) return undefined;
	const list = Array.isArray(raw) ? raw : [raw];
	for (const c of list) {
		if (isDshSessionCookie(c)) return String(c).split(";")[0].trim();
	}
	return undefined;
}

// ------------------------------------------------------ 登录失败节流（每 IP）
const attempts = new Map();
function throttled(ip) {
	const now = Date.now();
	const rec = attempts.get(ip) ?? { count: 0, since: now };
	if (now - rec.since > 60_000) {
		rec.count = 0;
		rec.since = now;
	}
	return rec.count >= 5;
}
function noteFailure(ip) {
	const now = Date.now();
	const rec = attempts.get(ip) ?? { count: 0, since: now };
	if (now - rec.since > 60_000) {
		rec.count = 0;
		rec.since = now;
	}
	rec.count += 1;
	attempts.set(ip, rec);
}

// ------------------------------------------------------------------ 页面
const STYLE = `:root{color-scheme:dark}
 body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
      background:#101216;color:#e6e8ee;font:16px/1.6 system-ui,-apple-system,"HarmonyOS Sans",sans-serif;padding:18px}
 .box{background:#181b21;padding:26px 22px;border-radius:14px;width:min(400px,92vw);box-shadow:0 8px 30px #0006}
 h1{font-size:18px;margin:0 0 6px}
 p{margin:0 0 16px;color:#98a1b3;font-size:13px}
 label{display:block;font-size:13px;color:#98a1b3;margin:12px 0 6px}
 input{width:100%;box-sizing:border-box;padding:12px;border-radius:9px;border:1px solid #2c313b;
       background:#0e1116;color:#e6e8ee;font-size:16px}
 button{width:100%;margin-top:18px;padding:12px;border:0;border-radius:9px;
        background:#3b82f6;color:#fff;font-size:16px;font-weight:600}
 .err{margin-top:12px;color:#f87171;font-size:13px;min-height:18px}
 code{background:#0e1116;padding:2px 6px;border-radius:5px;font-size:13px;word-break:break-all}`;

function page(title, inner, error = "") {
	return `<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>${STYLE}</style></head><body>
<div class="box">${inner}<div class="err">${error}</div></div></body></html>`;
}

const LOGIN_FORM = `<form method="POST" action="/__gw_login">
     <input type="password" name="password" autocomplete="current-password" autofocus>
     <button type="submit">进入</button>
   </form>`;

const LOGIN_PAGE = page("dsh 访问认证", `<h1>dsh 远程访问</h1><p>请输入访问密码</p>${LOGIN_FORM}`);

const MANUAL_TOKEN_FORM = `<form method="POST" action="/__gw_token">
     <label>dsh token</label>
     <input type="text" name="token" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" autofocus>
     <button type="submit">连接</button>
   </form>`;

function manualTokenPage(msg) {
	return page(
		"dsh 会话授权",
		`<h1>需要一次 dsh token</h1>
     <p>${msg}</p>
     <p>在电脑上打开 <code>%USERPROFILE%\\.dsh\\lan\\web-state.json</code>，
        复制其中的 <code>token</code>；或直接看负一屏那张「dsh 本次启动 token」卡片。</p>
     ${MANUAL_TOKEN_FORM}`
	);
}

function html(res, status, body, extraHeaders = {}) {
	res.writeHead(status, {
		"content-type": "text/html; charset=utf-8",
		"cache-control": "no-store",
		"x-content-type-options": "nosniff",
		...extraHeaders
	});
	res.end(body);
}

function gwCookieHeaders(sessionId) {
	const exp = Date.now() + SESSION_HOURS * 3600_000;
	return {
		"set-cookie": `${COOKIE_NAME}=${signSession({ sid: sessionId, exp })}; Path=/; Max-Age=${String(SESSION_HOURS * 3600)}; HttpOnly; SameSite=Lax; Secure`,
		"cache-control": "no-store"
	};
}

// ------------------------------------------------------ 与 dsh 的内部交互
/** 用 token 在内部换取 dsh 会话 cookie。成功返回 cookie 字符串。 */
function bootstrapDshSession(token) {
	return new Promise((resolve) => {
		const req = http.request(
			{
				hostname: BACKEND_HOST,
				port: BACKEND_PORT,
				method: "GET",
				path: `/?token=${encodeURIComponent(token)}`,
				headers: { host: `${BACKEND_HOST}:${String(BACKEND_PORT)}` }
			},
			(res) => {
				const cookie = extractDshCookie(res.headers);
				res.resume();
				resolve(res.statusCode === 303 || res.statusCode === 302 ? cookie : undefined);
			}
		);
		req.on("error", () => resolve(undefined));
		req.setTimeout(10_000, () => {
			req.destroy();
			resolve(undefined);
		});
		req.end();
	});
}

/** 后端是否就绪（电脑侧隧道是否在跑）。 */
function backendReady() {
	return new Promise((resolve) => {
		const req = http.request(
			{ hostname: BACKEND_HOST, port: BACKEND_PORT, method: "GET", path: "/__proxy_health", headers: { host: `${BACKEND_HOST}:${String(BACKEND_PORT)}` } },
			(res) => {
				let body = "";
				res.on("data", (c) => (body += c));
				res.on("end", () => resolve(res.statusCode === 200 && body.includes("entry-proxy ok")));
			}
		);
		req.on("error", () => resolve(false));
		req.setTimeout(6000, () => {
			req.destroy();
			resolve(false);
		});
		req.end();
	});
}

/** 设置（或更新）当前生效的 token，并重建 dsh 会话。 */
async function adoptToken(token, source) {
	const dshCookie = await bootstrapDshSession(token);
	if (!dshCookie) return false;
	tokenState.token = token;
	tokenState.dshCookie = dshCookie;
	tokenState.source = source;
	tokenState.at = Date.now();
	// 旧会话绑的是旧 token，改成新 cookie，让浏览器无需重新登录
	for (const [id, rec] of clientSessions) {
		if (rec.forToken !== token) {
			try {
				clientSessions.set(id, { ...rec, dshCookie, forToken: token });
			} catch {
				/* 忽略 */
			}
		}
	}
	return true;
}

// ------------------------------------------------------------------ 转发
function forward(req, res, session, body) {
	const headers = {};
	for (const [k, v] of Object.entries(req.headers)) {
		const key = k.toLowerCase();
		if (key === "host" || key === "origin" || key === "cookie" || key === "connection" || key === "upgrade" || key === "keep-alive" || key === "transfer-encoding") continue;
		if (v !== undefined) headers[key] = v;
	}
	headers.host = `${BACKEND_HOST}:${String(BACKEND_PORT)}`;
	if (session?.dshCookie) headers.cookie = session.dshCookie;

	const upstream = http.request(
		{ hostname: BACKEND_HOST, port: BACKEND_PORT, method: req.method, path: req.url, headers },
		(up) => {
			const out = { ...up.headers };
			delete out["set-cookie"];

			// dsh 会话失效：若网关手上有更新的 token，就静默重建，用户无感
			if ((up.statusCode === 401 || up.statusCode === 403) && session) {
				up.resume();
				const staleCookie = session.dshCookie;
				(async () => {
					if (tokenState.token && tokenState.dshCookie && tokenState.dshCookie !== staleCookie) {
						clientSessions.set(session.sid, { ...session, dshCookie: tokenState.dshCookie, forToken: tokenState.token });
						res.writeHead(303, { location: req.url ?? "/", "cache-control": "no-store" });
						res.end();
						return;
					}
					dropSession(session.sid);
					html(res, 200, manualTokenPage("原会话已失效（通常是 dsh 重启导致），请粘贴一次新的 token。"),
						{ "set-cookie": `${COOKIE_NAME}=; Path=/; Max-Age=0` });
				})();
				return;
			}

			res.writeHead(up.statusCode ?? 502, out);
			up.pipe(res);
		}
	);
	upstream.on("error", (error) => {
		if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
		res.end(`gateway: backend error: ${error.message}\n`);
	});
	if (body && body.length) upstream.write(body);
	req.pipe(upstream);
}

function readBody(req, res, limit, onDone) {
	let body = "";
	req.on("data", (c) => {
		body += c;
		if (body.length > limit) req.destroy();
	});
	req.on("end", () => onDone(body));
}

function json(res, status, obj) {
	res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
	res.end(JSON.stringify(obj));
}

// ------------------------------------------------------------------ 服务
const server = https.createServer(TLS_OPTIONS, (req, res) => {
	const ip = req.socket.remoteAddress ?? "unknown";
	const sessionId = verifySession(cookieValue(req.headers.cookie, COOKIE_NAME))?.sid;
	const session = getSession(sessionId);
	const url = new URL(req.url ?? "/", "https://gateway.invalid");

	// ---- 健康检查：认证之前，便于外部探活 ----
	if (url.pathname === "/__gw_health") {
		backendReady().then((ok) => {
			res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
			res.end(
				`auth-gateway ok -> ${BACKEND_HOST}:${String(BACKEND_PORT)} (backend ${ok ? "ready" : "DOWN"}; token ${tokenState.token ? `registered via ${tokenState.source}` : "NOT registered"})\n`
			);
		});
		return;
	}

	// ---- token 注册：供电脑上的插件调用，用注册密钥鉴权 ----
	if (req.method === "POST" && url.pathname === "/__gw_register") {
		readBody(req, res, MAX_CONTENT, async (body) => {
			let parsed;
			try {
				parsed = JSON.parse(body);
			} catch {
				json(res, 400, { ok: false, error: "invalid json" });
				return;
			}
			if (!registerKey) {
				json(res, 503, { ok: false, error: "gateway has no registration key configured" });
				return;
			}
			if (!registerKeyOk(parsed.key)) {
				noteFailure(ip); // 与密码尝试共用节流
				json(res, 401, { ok: false, error: "bad registration key" });
				return;
			}
			const token = typeof parsed.token === "string" ? parsed.token.trim() : "";
			if (!token) {
				json(res, 400, { ok: false, error: "missing token" });
				return;
			}
			const adopted = await adoptToken(token, "plugin");
			if (!adopted) {
				json(res, 400, { ok: false, error: "token rejected by dsh (expired?) or backend unreachable" });
				return;
			}
			console.log(`[gateway] token registered by plugin (${token.length} chars); ${clientSessions.size} browser session(s) updated`);
			json(res, 200, { ok: true, sessions: clientSessions.size });
		});
		return;
	}

	// ---- 退出登录 ----
	if (url.pathname === "/__gw_logout") {
		dropSession(sessionId);
		res.writeHead(303, { location: "/", "set-cookie": `${COOKIE_NAME}=; Path=/; Max-Age=0`, "cache-control": "no-store" });
		res.end();
		return;
	}

	// ---- 第一步：密码 ----
	if (req.method === "POST" && url.pathname === "/__gw_login") {
		if (throttled(ip)) {
			html(res, 429, page("dsh 访问认证", `<h1>dsh 远程访问</h1><p>请输入访问密码</p>${LOGIN_FORM}`, "尝试过多，请稍后再试"));
			return;
		}
		readBody(req, res, MAX_CONTENT, async (body) => {
			if (!passwordOk(new URLSearchParams(body).get("password") ?? "")) {
				noteFailure(ip);
				html(res, 401, page("dsh 访问认证", `<h1>dsh 远程访问</h1><p>请输入访问密码</p>${LOGIN_FORM}`, "密码不正确"));
				return;
			}
			const sid = newSessionId();
			putSession(sid, tokenState.dshCookie || "", ip);
			// 若网关已持有 token（插件已上报），直接进 GUI；否则退回手工粘贴
			if (tokenState.dshCookie) {
				res.writeHead(303, { location: "/", ...gwCookieHeaders(sid) });
				res.end();
				return;
			}
			const ready = await backendReady();
			if (!ready) {
				html(res, 200, manualTokenPage("电脑侧当前不可达（请确认电脑已开机、dsh 与 SSH 隧道在运行）；也可稍后重试。"), gwCookieHeaders(sid));
				return;
			}
			html(res, 200, manualTokenPage("网关尚未收到本次启动的 token（dsh 可能刚重启）。"), gwCookieHeaders(sid));
		});
		return;
	}

	// ---- 手工粘贴 token（兜底） ----
	if (req.method === "POST" && url.pathname === "/__gw_token") {
		if (!session) {
			html(res, 200, LOGIN_PAGE, "会话已过期，请重新输入密码");
			return;
		}
		readBody(req, res, MAX_CONTENT, async (body) => {
			const token = (new URLSearchParams(body).get("token") ?? "").trim();
			const ok = token ? await adoptToken(token, "manual") : false;
			if (!ok) {
				const hint = (await backendReady())
					? "token 无效或已过期（dsh 每次重启都会更换），请重新复制。"
					: "电脑侧不可达：请确认电脑已开机、dsh 已启动、SSH 隧道在运行。";
				html(res, 401, manualTokenPage(hint));
				return;
			}
			putSession(sessionId, tokenState.dshCookie, ip);
			res.writeHead(303, { location: "/", "cache-control": "no-store" });
			res.end();
		});
		return;
	}

	// ---- 首次带 ?token= 进入：自动完成授权并跳到干净地址 ----
	const urlToken = url.searchParams.get("token");
	if (urlToken && !session?.dshCookie) {
		if (!session) {
			html(res, 200, LOGIN_PAGE);
			return;
		}
		adoptToken(urlToken, "url").then((ok) => {
			if (!ok) {
				html(res, 401, manualTokenPage("URL 里的 token 无效或电脑侧不可达。"));
				return;
			}
			putSession(sessionId, tokenState.dshCookie, ip);
			res.writeHead(303, { location: "/", "cache-control": "no-store" });
			res.end();
		});
		return;
	}

	// ---- 未认证：登录页 ----
	if (!session) {
		html(res, 200, LOGIN_PAGE);
		return;
	}

	// ---- 已认证但还没有 dsh 会话：尽量用已注册 token 自动建，否则退回手工 ----
	if (!session.dshCookie) {
		collapseToSession(session, res);
		return;
	}

	forward(req, res, session);
});

/** 会话缺少 dsh cookie 时：已注册 token 就自动建立，否则要求手工粘贴。 */
async function collapseToSession(session, res) {
	if (tokenState.dshCookie) {
		clientSessions.set(session.sid, { ...session, dshCookie: tokenState.dshCookie, forToken: tokenState.token });
		res.writeHead(303, { location: "/", "cache-control": "no-store" });
		res.end();
		return;
	}
	if (await backendReady()) {
		html(res, 200, manualTokenPage("网关尚未收到本次启动的 token（dsh 可能刚重启）。"));
		return;
	}
	html(res, 200, manualTokenPage("电脑侧当前不可达（请确认电脑已开机、dsh 与 SSH 隧道在运行）。"));
}

// WebSocket / Upgrade：先过网关会话，再把内部 dsh cookie 注入后做原始 socket 隧道
server.on("upgrade", (req, clientSocket, head) => {
	const sid = verifySession(cookieValue(req.headers.cookie, COOKIE_NAME))?.sid;
	const session = getSession(sid);
	const cookie = session?.dshCookie || tokenState.dshCookie;
	if (!cookie) {
		clientSocket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
		return;
	}
	const headers = {};
	for (const [k, v] of Object.entries(req.headers)) {
		const key = k.toLowerCase();
		if (key === "host" || key === "origin" || key === "cookie" || key === "connection" || key === "upgrade" || key === "keep-alive") continue;
		if (v !== undefined) headers[key] = v;
	}
	headers.host = `${BACKEND_HOST}:${String(BACKEND_PORT)}`;
	headers.cookie = cookie;
	headers.connection = "Upgrade";
	if (req.headers.upgrade !== undefined) headers.upgrade = req.headers.upgrade;

	const upstream = http.request({ hostname: BACKEND_HOST, port: BACKEND_PORT, method: req.method, path: req.url, headers });
	upstream.on("upgrade", (up, upSocket, upHead) => {
		clientSocket.write(
			`HTTP/1.1 ${up.statusCode} ${up.statusMessage}\r\n` +
			Object.entries(up.headers).map(([k, v]) => `${k}: ${v}`).join("\r\n") + "\r\n\r\n"
		);
		if (upHead?.length) clientSocket.unshift(upHead);
		if (head?.length) upSocket.unshift(head);
		upSocket.pipe(clientSocket);
		clientSocket.pipe(upSocket);
		const close = () => {
			clientSocket.destroy();
			upSocket.destroy();
		};
		upSocket.on("error", close);
		clientSocket.on("error", close);
		upSocket.on("close", close);
		clientSocket.on("close", close);
	});
	upstream.on("error", () => clientSocket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
	upstream.end();
});

server.on("error", (error) => {
	console.error(`[gateway] ${error?.message ?? String(error)}`);
	process.exit(1);
});

server.listen(PORT, BIND_IP, () => {
	const loopback = BIND_IP === "127.0.0.1" || BIND_IP === "::1";
	console.log(`[gateway] https://${BIND_IP}:${String(PORT)}/  -> ${BACKEND_HOST}:${String(BACKEND_PORT)}`);
	console.log(`[gateway] 会话模型：网关持有 dsh 会话，浏览器只持有网关会话`);
	console.log(`[gateway] token 注册：${registerKey ? "已启用（/__gw_register，密钥鉴权）" : "未配置密钥，只能手工粘贴 token"}`);
	console.log(`[gateway] 绑定 ${BIND_IP}${loopback ? "（仅本机）" : "（对外暴露，请确认已设强密码）"}`);
});
