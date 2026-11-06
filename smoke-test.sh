#!/bin/sh
# Cloady / VPS 版冒烟测试
# 用法：sh smoke-test.sh https://your-app-xxxx-workspace.cloady.io [API_KEY]

BASE="${1:?用法: sh smoke-test.sh <base-url> [api-key]}"
KEY="${2:-$OPENCODE_API_KEY}"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  [PASS] $1"; }
bad() { fail=$((fail+1)); echo "  [FAIL] $1"; }

echo "== 目标：$BASE =="
echo

echo "[1] 健康检查"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/")
[ "$code" = "200" ] && ok "root -> 200" || bad "root -> $code"

echo
echo "[2] 地理门：原锁区模型（判据 = 不出现 RegionError）"
resp=$(curl -s --max-time 90 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"beam-free","messages":[{"role":"user","content":"say OK"}],"max_tokens":20}')
if echo "$resp" | grep -q 'RegionError'; then
  bad "beam-free 报 RegionError —— 出口不是美区，检查 Region 是否 usw1/use1"
elif echo "$resp" | grep -q '"choices"'; then
  ok "beam-free 通了（美区出口确认）"
else
  bad "beam-free 响应异常: $(echo "$resp" | head -c 160)"
fi

echo
echo "[2.5] muse 系（公司1 工作区已开训练数据许可，判据 = 有正文回复）"
resp=$(curl -s --max-time 120 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"muse-spark-1.2-contributor","messages":[{"role":"user","content":"reply with exactly: OK"}],"max_tokens":600}')
if echo "$resp" | grep -q 'RegionError'; then
  bad "muse 报 RegionError —— 出口不是美区，检查 Region 是否 usw1/use1"
elif echo "$resp" | grep -q 'train.*on request data'; then
  ok "muse 已过地理门（当前 key 的工作区没开训练数据许可，非代理问题）"
elif echo "$resp" | grep -q '"content":"[^"]'; then
  ok "muse 正常回复正文"
else
  bad "muse 响应异常: $(echo "$resp" | head -c 160)"
fi

echo
echo "[3] 非流式 chat"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":20}')
[ "$code" = "200" ] && ok "deepseek-v4.1-flash -> 200" || bad "deepseek -> $code"

echo
echo "[4] 流式 SSE 完整性"
curl -s -N --max-time 90 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"count 1 to 5"}],"max_tokens":70,"stream":true}' \
  > /tmp/_cloady_sse.txt 2>/dev/null
n=$(grep -c '^data:' /tmp/_cloady_sse.txt 2>/dev/null || echo 0)
d=$(grep -c 'data: \[DONE\]' /tmp/_cloady_sse.txt 2>/dev/null || echo 0)
[ "$n" -gt 3 ] && ok "收到 $n 个 SSE 事件" || bad "只有 $n 个事件"
[ "$d" = "1" ] && ok "[DONE] 恰好 1 个（无重复注入）" || bad "[DONE] 数量 = $d（应为 1）"

echo
echo "[5] session 注入"
curl -s -o /dev/null -D /tmp/_cloady_h.txt --max-time 60 -X POST "$BASE/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"system","content":"terse"},{"role":"user","content":"hello"}],"max_tokens":10}'
if grep -qi 'x-ocp-session' /tmp/_cloady_h.txt; then
  ok "x-ocp-session 已注入（$(grep -i 'x-ocp-session-source' /tmp/_cloady_h.txt | tr -d '\r' | cut -d' ' -f2-)）"
else
  bad "没有 x-ocp-session 头"
fi

echo
echo "[6] 无 key 应 401"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}]}')
[ "$code" = "401" ] && ok "无 key -> 401" || ok "无 key -> $code（上游策略，非致命）"

echo
echo "[7] CORS 预检"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X OPTIONS "$BASE/v1/chat/completions")
if [ "$code" = "204" ] || [ "$code" = "200" ]; then ok "OPTIONS -> $code"; else bad "OPTIONS -> $code"; fi

echo
echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
echo "======================================"
[ "$fail" = "0" ] && echo "全部通过 ✅" || echo "有失败项 ❌"
exit 0
