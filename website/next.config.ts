import type { NextConfig } from "next";
import { fileURLToPath } from "node:url";

const nextConfig: NextConfig = {
  /*
   * The wire contract lives outside this package, in `../contracts/ts`, and the bundler refuses to
   * reach above its project root by default. The root is therefore the repository, not this folder:
   * one contract, consumed by the relay, the tests and the browser, rather than a copy per surface
   * that can drift.
   */
  turbopack: {
    root: fileURLToPath(new URL("../", import.meta.url)),
  },

  /*
   * Exported as static assets for Cloudflare. Every route is already prerendered and all the
   * authenticated work happens in the browser against the API, so there is nothing for a Next
   * server to do at runtime — a server runtime here would be a second deployment surface with no
   * behaviour behind it.
   */
  output: "export",

  // The exporter cannot run the on-demand image optimiser, so images are served as-is.
  images: { unoptimized: true },

  // Emits `out/page/index.html` rather than `out/page.html`, which is what a static host expects.
  trailingSlash: true,

  reactStrictMode: true,
  poweredByHeader: false,
};

export default nextConfig;
