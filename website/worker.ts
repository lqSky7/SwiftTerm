interface Env {
  readonly API_UPSTREAM: string;
  readonly ASSETS: { fetch(request: Request): Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(request);
    const upstream = new URL(env.API_UPSTREAM);
    upstream.pathname = url.pathname.slice(4);
    upstream.search = url.search;
    const forwarded = new Request(upstream, request);
    forwarded.headers.set("skip_zrok_interstitial", "1");
    // Preserve Origin, cookies, CSRF and WebSocket headers; never follow an upstream redirect.
    return fetch(forwarded, { redirect: "manual" });
  },
};
