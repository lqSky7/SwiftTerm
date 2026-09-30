import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The website talks to the backend on a different origin during development, and same-origin in
  // production. Credentials travel in cookies, so the API client always sets `credentials:
  // "include"`; there is no proxy or rewrite that would hide a misconfigured base URL.
  reactStrictMode: true,
  poweredByHeader: false,
};

export default nextConfig;
