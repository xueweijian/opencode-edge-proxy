// ---------------------------------------------------------------------------
// x-opencode-session injection (OpenCode Go hard requirement since 2026-09-05)
// Priority chain (per request):
//   1. client sent x-opencode-session        -> pass through untouched
//   2. client sent x-conversation-id/x-session-id/x-correlation-id -> reuse it
//   3. JSON POST (generation) -> deterministic fingerprint
//      sha256("ocp1|model|system|first-user-msg")[0..16hex]
//      OpenAI-compatible clients resend full history every turn, so the
//      conversation prefix (system + first user msg) is stable per session
//      -> same key every turn -> sticky routing -> warm KV cache on one GPU
//   4. fallback: random UUID (non-JSON / no parseable body, like Zed standalone)
// UA governance: generic SDK user-agents are rewritten (opencode.ai CF blocks
// some of them with error 1010, and docs/go asks clients to self-identify).
//
// Ported verbatim from the Vercel Edge version; only the entry point differs
// (WinterCG addEventListener instead of `export default`).
// ---------------------------------------------------------------------------

const PROXY_UA = "cherry-opencode-proxy/1.0";
const GENERIC_UA_PATTERNS = [
  "okhttp", "okio", "dalvik", "java/", "apache-httpclient",
  "python-requests", "python-urllib", "python-httpx", "aiohttp", "httpx",
  "go-http-client", "dart", "dio", "undici", "axios", "node-fetch",
];
const SESSION_ALIASES = ["x-conversation-id", "x-session-id", "x-correlation-id"];

function pickClientSession(req) {
  const direct = req.headers.get("x-opencode-session");
  if (direct && direct.trim()) return { value: direct.trim(), source: "passthrough" };
  for (const alt of SESSION_ALIASES) {
    const v = req.headers.get(alt);
    if (v && v.trim()) return { value: v.trim(), source: alt };
  }
  return null;
}

function textFromContent(c) {
  if (typeof c === "string") return c;
  if (Array.isArray(c)) {
    return c.map((p) => (p && typeof p === "object" && typeof p.text === "string" ? p.text : "")).join("\n");
  }
  return "";
}

function extractPrefix(body) {
  try {
    if (!body || typeof body !== "object") return null;
    const model = typeof body.model === "string" ? body.model : "";
    const msgs = Array.isArray(body.messages) ? body.messages : [];
    let system = "";
    if (typeof body.system === "string") system = body.system; // anthropic style
    else if (Array.isArray(body.system)) system = textFromContent(body.system);
    let firstUser = "";
    for (const m of msgs) {
      if (!m || typeof m !== "object") continue;
      if (m.role === "system" && !system) { system = textFromContent(m.content); continue; }
      if (m.role === "user") { firstUser = textFromContent(m.content); break; }
    }
    return { model, system, firstUser };
  } catch {
    return null;
  }
}

async function resolveSession(req, bodyText) {
  const picked = pickClientSession(req);
  if (picked) return picked;
  const ct = req.headers.get("content-type") || "";
  if (bodyText && ct.includes("json")) {
    try {
      const p = extractPrefix(JSON.parse(bodyText));
      if (p) {
        const material = `ocp1|${p.model}|${p.system}|${p.firstUser}`;
        const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
        const hex = [...new Uint8Array(digest)].slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
        return { value: hex, source: "fingerprint" };
      }
    } catch {}
  }
  return { value: crypto.randomUUID(), source: "random" };
}

async function handler(req) {
  const url = new URL(req.url);

  if (req.method === "OPTIONS") {
    // WinterJS rejects `new Response(null, { status: 204 })` ("Expected Valid
    // Body"), so answer the CORS preflight with an empty 200 body instead.
    return new Response("", {
      status: 200,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, PATCH, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Max-Age": "86400",
        "Content-Length": "0",
      },
    });
  }

  if (url.pathname === "/" || url.pathname === "") {
    return new Response(JSON.stringify({ status: "healthy", region: "iad1" }), { headers: { "Content-Type": "application/json" }});
  }

  let targetPath = url.pathname;
  let targetUrl;
  if (targetPath.startsWith("/zen/")) {
    // /zen/* pass through as-is (covers /zen/go/v1/*, /zen/v1/*, ...)
    targetUrl = `https://opencode.ai${targetPath}${url.search}`;
  } else if (targetPath.startsWith("/v1/")) {
    targetUrl = `https://opencode.ai/zen/go/v1${targetPath.slice(3)}${url.search}`;
  } else {
    targetUrl = `https://opencode.ai/zen/go/v1${targetPath}${url.search}`;
  }

  const headers = new Headers(req.headers);
  const ua = (headers.get("user-agent") || "").toLowerCase();
  if (!ua || GENERIC_UA_PATTERNS.some((p) => ua.includes(p))) {
    headers.set("User-Agent", PROXY_UA);
  }
  headers.delete("host");
  headers.delete("x-forwarded-host");
  headers.delete("x-forwarded-proto");
  headers.delete("x-real-ip");
  headers.delete("x-forwarded-for");
  headers.delete("x-vercel-id");
  headers.delete("x-vercel-ip-country");
  headers.delete("x-vercel-ip-city");
  headers.delete("cf-connecting-ip");
  headers.delete("cf-ipcountry");
  headers.delete("cf-ray");
  headers.delete("cf-visitor");
  headers.delete("true-client-ip");
  // body is re-serialized below -> a stale length/encoding breaks the upstream call
  headers.delete("content-length");
  headers.delete("content-encoding");

  // session injection: only for body-carrying requests (generation endpoints).
  // GET (e.g. /models) untouched; JSON body -> fingerprint / aliases / passthrough.
  // NOTE WinterJS: reading req.body marks the stream consumed, so never touch
  // req.body before req.text() (otherwise "Body already used").
  let bodyInit = null;
  let session = null;
  if (!["GET", "HEAD"].includes(req.method)) {
    const ct = req.headers.get("content-type") || "";
    let bodyText = null;
    if (ct.includes("json")) {
      bodyText = await req.text();
      bodyInit = bodyText;
    } else {
      bodyInit = req.body;
    }
    session = await resolveSession(req, bodyText);
    headers.set("x-opencode-session", session.value);
  }

  try {
    const upstreamRes = await fetch(targetUrl, {
      method: req.method,
      headers: headers,
      body: bodyInit,
      redirect: "follow",
    });

    const resHeaders = new Headers(upstreamRes.headers);
    resHeaders.set("Access-Control-Allow-Origin", "*");
    resHeaders.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
    resHeaders.set("Access-Control-Allow-Headers", "*");
    if (session) {
      // observability only (not forwarded upstream)
      resHeaders.set("x-ocp-session", session.value);
      resHeaders.set("x-ocp-session-source", session.source);
    }

    const contentType = resHeaders.get("content-type") || "";

    // SSE finish-signal patch: Chat Completions clients (Cherry Studio, Android
    // apps) expect `finish_reason:"stop"` + `data: [DONE]`; opencode.ai often
    // closes the stream without them -> AI_FinishReasonError "other".
    // The Responses protocol terminates with its own semantic events
    // (response.completed / response.incomplete) and has NO [DONE] concept:
    // injecting chat-style frames there breaks strict Responses parsers (zcode
    // -> zod Type validation failed on unexpected chat.completion.chunk).
    // Gate: only chat-completions-style endpoints get patched; everything else
    // (e.g. /responses) is passed through byte-transparent.
    const isChatCompletions = /\/(chat\/)?completions$/.test(url.pathname);
    // Capture the stream ONCE: WinterJS throws "Response body has already been
    // used" if the .body getter is evaluated a second time.
    const upstreamBody = upstreamRes.body;
    if (isChatCompletions && contentType.includes("text/event-stream") && upstreamBody) {
      // A streaming body must not carry a stale length.
      resHeaders.delete("content-length");
      // Upstream behaviour changed: opencode.ai now sometimes DOES emit
      // finish_reason:"stop" and `data: [DONE]` itself. Blindly appending our
      // own pair would produce a second (meaningless) terminal frame, and a
      // strict client stops at the first [DONE], silently dropping anything
      // after it. So track what the stream already sent and only fill the gaps.
      const decoder = new TextDecoder();
      let tail = "";
      let sawDone = false;
      let sawFinish = false;
      const transformStream = new TransformStream({
        transform(chunk, controller) {
          controller.enqueue(chunk);
          // keep a small rolling window: sse frames are line-delimited
          tail = (tail + decoder.decode(chunk, { stream: true })).slice(-4096);
          if (tail.includes("[DONE]")) sawDone = true;
          if (/"finish_reason"\s*:\s*"(stop|length|tool_calls|content_filter)"/.test(tail)) sawFinish = true;
        },
        flush(controller) {
          // OpenCode's API may close without sending finish_reason:"stop" and [DONE]
          // We inject the missing parts so clients like Cherry Studio don't throw
          // AI_FinishReasonError "other".
          let extra = "";
          if (!sawFinish) {
            extra += `data: {"id":"chatcmpl-end","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n`;
          }
          if (!sawDone) {
            extra += `data: [DONE]\n\n`;
          }
          if (extra) controller.enqueue(new TextEncoder().encode(extra));
        }
      });
      return new Response(upstreamBody.pipeThrough(transformStream), {
        status: upstreamRes.status,
        statusText: upstreamRes.statusText,
        headers: resHeaders,
      });
    }

    return new Response(upstreamBody, {
      status: upstreamRes.status,
      statusText: upstreamRes.statusText,
      headers: resHeaders,
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 502, headers: { "Access-Control-Allow-Origin": "*" } });
  }
}

// WinterCG 入口：等价于 Vercel 的 export default handler
addEventListener("fetch", (event) => {
  event.respondWith(
    handler(event.request).catch((err) =>
      new Response(
        JSON.stringify({ error: String((err && err.message) || err) }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      )
    )
  );
});
