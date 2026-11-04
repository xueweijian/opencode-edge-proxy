#!/bin/sh
# 代理上线自测 —— 部署到任何平台后都能用
# 用法: sh smoke-test.sh https://your-proxy-domain
#       API key 从环境变量 OPENCODE_API_KEY_COMPANY2 读（可换任意 key）
set -u

BASE="${1:-}"
if [ -z "$BASE" ]; then
  echo "用法: sh smoke-test.sh https://your-proxy-domain"
  exit 1
fi
BASE=$(echo "$BASE" | sed 's:/*$::')
KEY="${OPENCODE_API_KEY_COMPANY2:-${OPENCODE_API_KEY:-}}"
if [ -z "$KEY" ]; then
  echo "缺少 API key：导出 OPENCODE_API_KEY_COMPANY2 或 OPENCODE_API_KEY"
  exit 1
fi

pass=0; fail=0
ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }

echo "===== 目标: $BASE ====="

echo
echo "[1] 健康检查"
code=$(curl -s -o /tmp/st_body -w '%{http_code}' --max-time 20 "$BASE/")
if [ "$code" = "200" ]; then ok "GET / -> $code  $(head -c 120 /tmp/st_body)"; else bad "GET / -> $code"; fi

echo
echo "[2] 模型列表透传"
code=$(curl -s -o /tmp/st_models -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" "$BASE/zen/go/v1/models")
n=$(python3 -c "
import json
try: print(len(json.load(open('/tmp/st_models')).get('data',[])))
except Exception: print(0)
" 2>/dev/null)
if [ "$code" = "200" ] && [ "${n:-0}" -gt 5 ]; then ok "GET /zen/go/v1/models -> $code, $n 个模型"; else bad "models -> $code, count=$n"; fi

echo
echo "[3] 地理门：muse（必须 OK，否则不是美区出口）"
resp=$(curl -s --max-time 90 -X POST "$BASE/zen/go/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
  -H "Content-Type: application/json" \
  -d '{"model":"muse-spark-1.2-contributor","messages":[{"role":"user","content":"说 ok"}],"max_tokens":200}')
if echo "$resp" | grep -q 'RegionError'; then
  bad "muse 报 RegionError —— 出口不是美区，检查 app.yaml 的 locality.regions"
elif echo "$resp" | grep -q '"choices"'; then
  ok "muse 通了（无 RegionError）"
else
  bad "muse 响应异常: $(echo "$resp" | head -c 200)"
fi

echo
echo "[4] 对照：付费模型（业务不受地理门影响）"
resp=$(curl -s --max-time 60 -X POST "$BASE/zen/go/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":300}')
if echo "$resp" | grep -q '"choices"'; then ok "deepseek-v4.1-flash 通了"; else bad "deepseek: $(echo "$resp" | head -c 200)"; fi

echo
echo "[5] session 注入头回显"
hdrs=$(curl -s -D - -o /dev/null --max-time 40 -X POST "$BASE/zen/go/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":20}')
if echo "$hdrs" | grep -qi 'x-ocp-session'; then
  ok "x-ocp-session 已注入 ($(echo "$hdrs" | grep -i 'x-ocp-session-source' | tr -d '\r' | head -1))"
else
  bad "未见 x-ocp-session 回显"
fi

echo
echo "[6] SSE 流式 + 收尾补丁（真流式要看到分块到达）"
t0=$(date +%s)
curl -sN --max-time 90 -X POST "$BASE/zen/go/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"数到五"}],"stream":true,"max_tokens":200}' \
  > /tmp/st_sse
t1=$(date +%s)
chunks=$(grep -c '^data:' /tmp/st_sse 2>/dev/null || echo 0)
has_done=$(grep -c 'data: \[DONE\]' /tmp/st_sse 2>/dev/null || echo 0)
has_stop=$(grep -c '"finish_reason":"stop"' /tmp/st_sse 2>/dev/null || echo 0)
if [ "$chunks" -gt 2 ]; then ok "收到 $chunks 个 SSE 事件（耗时 $((t1-t0))s）"; else bad "SSE 事件只有 $chunks 个"; fi
if [ "$has_done" -gt 0 ]; then ok "有 [DONE] 收尾帧"; else bad "缺 [DONE] 收尾帧"; fi
if [ "$has_stop" -gt 0 ]; then ok "有 finish_reason:stop"; else bad "缺 finish_reason:stop"; fi

echo
echo "[7] CORS 预检"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X OPTIONS "$BASE/zen/go/v1/chat/completions")
if [ "$code" = "204" ]; then ok "OPTIONS -> 204"; else bad "OPTIONS -> $code"; fi

echo
echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
echo "======================================"
[ "$fail" -eq 0 ] && echo "全部通过 ✅" || echo "有失败项 ❌ —— 详见上面 [FAIL]"
exit "$fail"
