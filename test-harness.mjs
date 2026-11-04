// Wasmer/WinterCG 版代码的本地验证器
// 用 shim 模拟 service worker 环境，真正执行 src/index.js 的注册与请求处理，
// 确认移植没有把逻辑改坏（不依赖 Wasmer 平台就能测）。
import { createServer } from "node:http";

const listeners = [];
globalThis.addEventListener = (type, fn) => { if (type === "fetch") listeners.push(fn); };

const mod = await import("./src/index.js");
console.log(`[1] 模块加载成功，注册了 ${listeners.length} 个 fetch 监听器`);
if (listeners.length !== 1) { console.log("  [FAIL] 监听器数量异常"); process.exit(1); }
console.log("  [PASS] 注册了 1 个 fetch 事件监听器");

// 把 service worker 的 fetch 事件适配成 Node http server
const dispatch = (request) =>
  new Promise((resolve, reject) => {
    const event = { request, respondWith: (p) => resolve(p) };
    try {
      for (const fn of listeners) fn(event);
    } catch (e) { reject(e); }
  });

const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? Buffer.concat(chunks) : null;
  const url = `http://127.0.0.1:8098${req.url}`;
  const request = new Request(url, {
    method: req.method,
    headers: req.headers,
    body: ["GET", "HEAD"].includes(req.method) ? undefined : body,
  });
  try {
    const response = await dispatch(request);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body) {
      const reader = response.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(value);
      }
    }
    res.end();
  } catch (e) {
    console.log("  [FAIL] 处理请求抛异常:", e.message);
    res.writeHead(500); res.end(String(e.message));
  }
});

server.listen(8098, "127.0.0.1", () => console.log("[2] Wasmer 版已在 8098 跑起来（shim 模式）"));
