import type { NextConfig } from "next";

const nextConfig: NextConfig = {
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
