/**
 * verify-gateway.mjs — 一条命令查清"远程端为什么进不去"。
 *
 * 背景（2026-09-27 真实事故）：网关把 dsh token 存在**进程内存**里，每次 dsh 重启
 * 都必须由电脑上的 token-broadcast 插件重新注册一次。那次注册只试一次、失败即静默放弃，
 * 结果 dsh 卡死手工重启后网关没收到新 token，远程端一直提示
 * "网关尚未收到本次启动的 token"，手工粘卡片里的 token 也无效。
 *
 * 用法：
 *   node verify-gateway.mjs              # 只体检，不改动任何东西
 *   node verify-gateway.mjs --register    # 体检 + token 缺失时补注册
 *
 * 配置（**不写死在代码里**，避免把公网地址与密钥路径提交进仓库）：
 *   DSH_GW_HOST      网关主机，默认 127.0.0.1（本机调试用）
 *   DSH_GW_PORT      网关端口，默认 18443
 *   DSH_GW_KEY_FILE  网关注册密钥文件路径（仅 --register 需要）
 *   DSH_ENTRY_PORT   局域网入口端口，默认 3081
 *
 * 体检内容：
 *   1. 本机 dsh 是否在跑、当前 token、web-state 是否属于当前进程
 *   2. 网关 /__gw_health：可达性 + 后端是否 ready + token 是否已注册
 *   3. 局域网入口：带 token 是否 303（WebSocket 由入口代理负责，见 dsh-entry-proxy.mjs）
 *   4. 注册状态文件（token-broadcast 写的 register-status.json）
 *
 * 不打印任何密钥；token 只显示尾部 8 位。
 */
import { readFileSync, existsSync, statSync } from "node:fs";
import { request as httpsRequest } from "node:https";
import { request as httpRequest } from "node:http";
import { homedir, networkInterfaces } from "node:os";
import { join } from "node:path";

const HOME = homedir();
const STATE = join(HOME, ".dsh", "lan", "web-state.json");
const REGISTER_STATUS = join(HOME, ".dsh", "lan", "token-broadcast", "register-status.json");
const KEY_FILE = process.env.DSH_GW_KEY_FILE ?? join(HOME, ".dsh", "lan", "gw-register-key.txt");
const GATEWAY = {
	host: process.env.DSH_GW_HOST ?? "127.0.0.1",
	port: Number(process.env.DSH_GW_PORT ?? 18443)
};
const ENTRY_PORT = Number(process.env.DSH_ENTRY_PORT ?? 3081);
const DO_REGISTER = process.argv.includes("--register");

const ok = (s) => `✅ ${s}`;
const bad = (s) => `❌ ${s}`;
const warn = (s) => `⚠️  ${s}`;

function readJson(path) {
	try {
		return JSON.parse(readFileSync(path, "utf8").replace(/^\uFEFF/, ""));
	} catch {
		return undefined;
	}
}

function httpGet(url, { insecure = false, timeout = 10000 } = {}) {
	return new Promise((resolve) => {
		let target;
		try {
			target = new URL(url);
		} catch {
			resolve({ status: 0, body: "bad url", headers: {} });
			return;
		}
		const secure = target.protocol !== "http:";
		const request = secure ? httpsRequest : httpRequest;
		const req = request(
			{
				hostname: target.hostname,
				port: target.port || (secure ? 443 : 80),
				path: target.pathname + target.search,
				method: "GET",
				timeout,
				rejectUnauthorized: !insecure
			},
			(res) => {
				let data = "";
				res.on("data", (c) => (data += c));
				res.on("end", () => resolve({ status: res.statusCode ?? 0, body: data, headers: res.headers }));
			}
		);
		req.on("error", (e) => resolve({ status: 0, body: `ERR ${e.message}`, headers: {} }));
		req.on("timeout", () => {
			req.destroy();
			resolve({ status: 0, body: "TIMEOUT", headers: {} });
		});
		req.end();
	});
}

function httpPost(url, body, { insecure = false, timeout = 15000 } = {}) {
	return new Promise((resolve) => {
		const target = new URL(url);
		const payload = Buffer.from(JSON.stringify(body), "utf8");
		const secure = target.protocol !== "http:";
		const request = secure ? httpsRequest : httpRequest;
		const req = request(
			{
				hostname: target.hostname,
				port: target.port || (secure ? 443 : 80),
				path: target.pathname + target.search,
				method: "POST",
				headers: { "content-type": "application/json", "content-length": String(payload.length) },
				timeout,
				rejectUnauthorized: !insecure
			},
			(res) => {
				let data = "";
				res.on("data", (c) => (data += c));
				res.on("end", () => resolve({ status: res.statusCode ?? 0, body: data, headers: res.headers }));
			}
		);
		req.on("error", (e) => resolve({ status: 0, body: `ERR ${e.message}`, headers: {} }));
		req.on("timeout", () => {
			req.destroy();
			resolve({ status: 0, body: "TIMEOUT", headers: {} });
		});
		req.write(payload);
		req.end();
	});
}

/** LAN 地址：取第一个非内部、非链路本地的 IPv4（与入口代理的默认绑定一致）。 */
function detectLan() {
	for (const addrs of Object.values(networkInterfaces())) {
		for (const a of addrs ?? []) {
			if (a.family === "IPv4" && !a.internal && !a.address.startsWith("169.254.")) return a.address;
		}
	}
	return "";
}

async function main() {
	console.log("=== dsh 远程访问链路体检 ===\n");
	let problems = 0;

	// ---- 1) 本机 dsh 与 token
	const state = readJson(STATE);
	if (!state?.token) {
		console.log(bad(`读不到 ${STATE}`));
		problems += 1;
	} else {
		const ageSec = Math.round((Date.now() - Date.parse(state.startedAt ?? 0)) / 1000);
		console.log(ok(`dsh 状态：pid ${state.pid}，token …${state.token.slice(-8)}，启动于 ${state.startedAt}（${Math.round(ageSec / 60)} 分钟前）`));
	}

	// ---- 2) 网关健康
	const health = await httpGet(`https://${GATEWAY.host}:${GATEWAY.port}/__gw_health`, { insecure: true });
	if (health.status !== 200) {
		console.log(bad(`网关不可达（HTTP ${health.status}）：${String(health.body).slice(0, 120)}`));
		problems += 1;
	} else {
		const registered = /token registered via (\w+)/.exec(health.body);
		const ready = /backend (ready|DOWN)/.exec(health.body);
		console.log(ok(`网关可达：${String(health.body).trim()}`));
		if (ready?.[1] === "DOWN") {
			console.log(bad("网关报告后端 DOWN —— SSH 反向隧道或 18080 入口没通"));
			problems += 1;
		}
		if (!registered) {
			console.log(bad("网关尚未收到本次 token —— 这正是远程端提示“网关没有收到 token”的原因"));
			problems += 1;
		} else {
			console.log(ok(`token 已注册（来源：${registered[1]}）`));
		}
	}

	// ---- 3) 局域网入口
	const lan = detectLan();
	if (lan) {
		const entryUrl = `http://${lan}:${String(ENTRY_PORT)}/?token=${state?.token ?? ""}`;
		const r = await httpGet(entryUrl, { timeout: 8000 });
		if (r.status === 303) console.log(ok(`局域网入口正常（http://${lan}:${String(ENTRY_PORT)} 带 token → 303）`));
		else {
			console.log(bad(`局域网入口异常（http://${lan}:${String(ENTRY_PORT)} 带 token → HTTP ${r.status}，期望 303）`));
			problems += 1;
		}
	} else {
		console.log(warn("探测不到局域网 IPv4，跳过局域网检查"));
	}

	// ---- 4) 插件写的注册状态
	if (existsSync(REGISTER_STATUS)) {
		const st = readJson(REGISTER_STATUS);
		const line = `token-broadcast 注册状态：${st.ok ? "成功" : "失败"}（${st.at}，HTTP ${st.status ?? "-"}）`;
		console.log(st.ok ? ok(line) : bad(`${line} ${String(st.body ?? st.reason ?? "").slice(0, 120)}`));
		if (!st.ok) problems += 1;
	} else {
		console.log(warn(`${REGISTER_STATUS} 不存在（该文件由新版 token-broadcast 写入）`));
	}

	// ---- 5) 可选：补注册
	if (DO_REGISTER && state?.token && existsSync(KEY_FILE)) {
		const key = readFileSync(KEY_FILE, "utf8").trim();
		const res = await httpPost(`https://${GATEWAY.host}:${GATEWAY.port}/__gw_register`, { token: state.token, key }, { insecure: true });
		const okReg = res.status === 200 && /"ok"\s*:\s*true/.test(res.body);
		console.log(okReg ? ok(`已补注册：${res.body.trim()}`) : bad(`补注册失败（HTTP ${res.status}）：${res.body.trim()}`));
		if (!okReg) problems += 1;
	}

	console.log(`\n=== 结论：${problems === 0 ? "链路健康 ✅" : `发现 ${problems} 处问题 ❌`} ===`);
	if (problems > 0 && !DO_REGISTER) console.log("提示：加 --register 可在 token 缺失时自动补注册。");
	process.exit(problems === 0 ? 0 : 1);
}

await main();
