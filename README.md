# opencode-proxy

OpenCode API 反向代理，部署在 Wasmer Edge（WinterJS 运行时）。

**线上地址：https://wasmer.1ciyuan.cn**（出口 `us-losa1` 洛杉矶）

## 为什么需要它

`opencode.ai` 的部分模型（muse-spark-1.2/1.3-contributor、beam-free）有 IP 地理门，
中国大陆直连返回 `RegionError: This model is not available in your country`。
本代理从美区出口转发请求，绕过地理门。

## 功能

- **UA 治理**：通用 SDK UA（okhttp / python-requests / undici 等）改写为可识别的代理 UA，
  避免 opencode.ai 的 Cloudflare 1010 拦截
- **`x-opencode-session` 注入**：OpenCode Go 的硬性要求（2026-09-05 起）。优先级链：
  1. 客户端自带 → 原样透传
  2. `x-conversation-id` / `x-session-id` / `x-correlation-id` → 复用
  3. JSON POST → 确定性指纹 `sha256("ocp1|model|system|first-user")[0:8]`
     （OpenAI 兼容客户端每轮重发完整历史，会话前缀稳定 → 同一 key → 粘性路由 → KV cache 命中）
  4. 兜底随机 UUID
- **SSE finish 补丁**：opencode.ai 有时不发 `finish_reason:"stop"` 和 `data: [DONE]`，
  导致 Cherry Studio 报 `AI_FinishReasonError "other"`。仅对 chat-completions 端点补齐，
  且**只补缺失的那一半**（上游现已常自带 `[DONE]`，重复注入会让严格客户端提前截断）；
  `/responses` 端点字节透明（它有自己的一套终止语义，注入会破坏严格解析器）
- **客户端 IP 清洗**：删除 `x-forwarded-for` / `cf-connecting-ip` / `x-vercel-ip-*` 等，
  上游只看到平台出口 IP
- **CORS**：全放开，含 OPTIONS 预检

## 路由

| 入站 | 出站 |
|---|---|
| `/zen/*` | `https://opencode.ai/zen/*`（原样） |
| `/v1/*` | `https://opencode.ai/zen/go/v1/*` |
| 其他 | `https://opencode.ai/zen/go/v1/*` |
| `/` | 健康检查 `{"status":"healthy"}` |

## 与 Vercel 原版的差异

`src/index.js` 与 Vercel Edge 版逐行对应，只有三处必要的平台适配：

1. `export default async function handler` → 函数 + 末尾 `addEventListener("fetch", ...)`（WinterCG 入口）
2. 删除 `export const config = { runtime: "edge", regions: ["iad1"] }`（区域改由 `app.yaml` 的 `locality.regions` 控制）
3. 修掉 WinterJS 的 body 语义差异（见下）

### WinterJS 踩坑记录

| 症状 | 根因 | 修法 |
|---|---|---|
| `Body already used` | 先取 `req.body` 再 `await req.text()`，取 `.body` 即标记流已消费 | 先判 content-type，再决定读 `req.text()` 还是 `req.body` |
| `Response body has already been used` | `upstreamRes.body` getter 被求值两次（条件判断 + `pipeThrough`） | 提前 `const upstreamBody = upstreamRes.body;` 单次捕获 |
| OPTIONS 预检 500 `Expected Valid Body` | WinterJS 不接受 `new Response(null, { status: 204 })` | 改为 `new Response("", { status: 200, "Content-Length": "0" })` |
| 部署报 `The version 0.1.0 already exists` | Wasmer 包版本不可复用 | CI 用 `github.run_number` 每次自动 bump patch 号 |

## 部署

CI 自动部署（push 到 main 或手动 dispatch）：

1. 仓库 Settings → Secrets 添加 `WASMER_TOKEN`
   （必须是 **user access token**：`wap_` 前缀 68 字符；
   `sk_` 前缀的 workspace/namespace token 只能读 GraphQL，`wasmer login` 存下凭据后仍无法建立会话）
2. workflow 自动把 `wasmer.toml` 的版本改成 `0.2.<run_number>`
3. `wasmer deploy --owner llm --app-name opencode-proxy`

手动部署：

```bash
curl https://get.wasmer.io -sSfL | sh
export WASMER_TOKEN=wap_...
wasmer login "$WASMER_TOKEN" --no-browser   # 注意：token 是位置参数，不是 --token
wasmer deploy --non-interactive --owner llm --app-name opencode-proxy
```

## 域名

`wasmer.1ciyuan.cn` → CNAME `19hni9t8xmwp.id.wasmer.app`（Cloudflare **DNS-only/灰云**，
不经过 CF 代理，确保上游看到 Wasmer 美区 IP 而不是 CF IP）。

## 本地测试

```bash
node --check src/index.js
sh smoke-test.sh http://127.0.0.1:8098
```

`smoke-test.sh` 会验证 8 项，其中第 6 项是地理门（原锁区模型必须 OK，否则不是美区出口）。

## 配置

`app.yaml` 的 `locality.regions` 锁定出口区域，默认 `us-losa1`（洛杉矶）。
备选：`us-ashburn`、`us-hillsboro`。

Wasmer Free 额度：Ingress 150GB + Egress 150GB / 月（分开计）、100 万请求、100 apps。

## 本地开发

```bash
# 用 shim 模拟 WinterCG 环境
node test-harness.mjs
```
