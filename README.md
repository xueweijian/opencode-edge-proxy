# opencode-proxy

OpenCode API 反向代理，部署在 Wasmer Edge（WinterJS 运行时）。

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
- **SSE finish 补丁**：opencode.ai 常不发 `finish_reason:"stop"` 和 `data: [DONE]`，
  导致 Cherry Studio 报 `AI_FinishReasonError "other"`。仅对 chat-completions 端点补齐；
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

## 部署

CI 自动部署（push 到 main 触发）：

1. 在仓库 Settings → Secrets 添加 `WASMER_TOKEN`
2. 在 Wasmer 创建 app（或在 workflow 里改 `--app-name`）
3. push 即部署

手动部署：

```bash
curl https://get.wasmer.io -sSfL | sh
export WASMER_TOKEN=sk_...
wasmer deploy --non-interactive --owner llm --app-name opencode-proxy
```

## 本地测试

```bash
node --check src/index.js
sh smoke-test.sh http://127.0.0.1:8098
```

`smoke-test.sh` 会验证 7 项，其中第 3 项是地理门（muse 必须 OK，否则不是美区出口）。

## 配置

`app.yaml` 的 `locality.regions` 锁定出口区域，默认 `us-losa1`（洛杉矶）。
备选：`us-ashburn`、`us-hillsboro`。

## 本地开发

```bash
# 用 shim 模拟 WinterCG 环境
node test-harness.mjs
```
