#!/bin/sh
# 指纹稳定性 + 真流式验证
BASE="${1:-http://127.0.0.1:8099}"
KEY="${OPENCODE_API_KEY_COMPANY2:-${OPENCODE_API_KEY:-}}"
[ -z "$KEY" ] && { echo "缺 key"; exit 1; }

echo "===== A) session 指纹稳定性 ====="
echo "同一会话（system+首条user相同，后续history增长）应得到同一 session 值"
for n in 1 2 3; do
  # 构造 history 逐步变长，但 system + 首条 user 保持恒定
  body=$(python3 -c "
import json
msgs=[{'role':'system','content':'You are helpful.'},{'role':'user','content':'固定开场白'}]
for i in range($n): msgs.append({'role':'assistant','content':'ok'}); msgs.append({'role':'user','content':'继续 %d'%i})
print(json.dumps({'model':'deepseek-v4.1-flash','messages':msgs,'max_tokens':16}))
")
  sess=$(curl -s -D - -o /dev/null --max-time 60 -X POST "$BASE/zen/go/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
    -H "Content-Type: application/json" -d "$body" \
    | grep -i '^x-ocp-session:' | tr -d '\r' | awk '{print $2}')
  echo "  turn $n -> $sess"
done

echo
echo "===== B) 不同会话应得到不同指纹 ====="
for w in "话题甲" "话题乙"; do
  body=$(python3 -c "
import json
print(json.dumps({'model':'deepseek-v4.1-flash','messages':[{'role':'system','content':'sys'},{'role':'user','content':'$w'}],'max_tokens':16}))
")
  sess=$(curl -s -D - -o /dev/null --max-time 60 -X POST "$BASE/zen/go/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
    -H "Content-Type: application/json" -d "$body" \
    | grep -i '^x-ocp-session:' | tr -d '\r' | awk '{print $2}')
  echo "  '$w' -> $sess"
done

echo
echo "===== C) 客户端自带 session 应原样透传 ====="
sess=$(curl -s -D - -o /dev/null --max-time 60 -X POST "$BASE/zen/go/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
  -H "x-opencode-session: my-custom-session-123" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":16}' \
  | grep -iE '^x-ocp-session(-source)?:' | tr -d '\r')
echo "$sess"
echo "$sess" | grep -q 'my-custom-session-123' && echo "  [PASS] 原样透传" || echo "  [FAIL] 未透传"

echo
echo "===== D) 真流式验证（逐块时间间隔）====="
echo "如果是一次性返回，所有时间戳会挤在最后；真流式应均匀分布"
curl -sN --max-time 120 -X POST "$BASE/zen/go/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H "User-Agent: cherry-opencode-proxy/1.0" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"从1数到15，每个数字单独一行"}],"stream":true,"max_tokens":500}' \
| python3 -c "
import sys, time
t0=time.time(); times=[]
for line in sys.stdin:
    if line.startswith('data:'):
        times.append(time.time()-t0)
if not times:
    print('  没收到事件'); sys.exit()
total=times[-1]
print(f'  事件数: {len(times)}  总耗时: {total:.2f}s')
if len(times)>1:
    gaps=[times[i+1]-times[i] for i in range(len(times)-1)]
    first=times[0]
    print(f'  首个事件: {first:.2f}s  最大间隔: {max(gaps):.2f}s')
    # 判定：首事件早于总耗时 80%，且事件分散在多秒内 = 真流式
    if first < total*0.8 and total > 1.0 and len(times) > 5:
        print('  [PASS] 真流式（内容边生成边到达）')
    elif total < 1.0:
        print('  [WARN] 响应太快无法判定，重跑一次或用更长 prompt')
    else:
        print('  [FAIL] 疑似缓冲（内容被攒到最后一起下发）')
"
