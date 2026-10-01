import assert from "node:assert/strict";
import { it } from "node:test";
import worker from "../worker.ts";

it("proxies session cookies, CSRF, queries and socket upgrades to a fixed upstream", async () => {
  const original = globalThis.fetch;
  const seen: Request[] = [];
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    seen.push(request);
    return new Response(null, { status: 204, headers: { "set-cookie": "swiftterm_session=s; Path=/; HttpOnly; Secure" } });
  };
  const env = {
    API_UPSTREAM: "https://upstream.example",
    ASSETS: { fetch: async () => new Response("asset") },
  };
  try {
    const response = await worker.fetch(new Request("https://site.example/api/auth/logout?x=1", {
      method: "POST", headers: { origin: "https://site.example", cookie: "swiftterm_session=s", "x-swiftterm-csrf": "c" },
    }), env);
    assert.equal(seen[0]?.url, "https://upstream.example/auth/logout?x=1");
    assert.equal(seen[0]?.headers.get("origin"), "https://site.example");
    assert.equal(seen[0]?.headers.get("cookie"), "swiftterm_session=s");
    assert.equal(seen[0]?.headers.get("x-swiftterm-csrf"), "c");
    assert.equal(seen[0]?.redirect, "manual");
    assert.equal(seen[0]?.headers.get("skip_zrok_interstitial"), "1");
    assert.match(response.headers.get("set-cookie")!, /HttpOnly/);
    await worker.fetch(new Request("https://site.example/api/live/id", {
      headers: { upgrade: "websocket", "sec-websocket-protocol": "swiftterm.live.v1" },
    }), env);
    assert.equal(seen[1]?.url, "https://upstream.example/live/id");
    assert.equal(seen[1]?.headers.get("upgrade"), "websocket");
    assert.equal(seen[1]?.headers.get("skip_zrok_interstitial"), "1");
    assert.equal(seen[1]?.headers.get("sec-websocket-protocol"), "swiftterm.live.v1");
    assert.equal(await (await worker.fetch(new Request("https://site.example/account/"), env)).text(), "asset");
    assert.equal(seen.length, 2);
  } finally {
    globalThis.fetch = original;
  }
});
