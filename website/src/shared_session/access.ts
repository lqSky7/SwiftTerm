/** Keep invitation fragments when signing in, without accepting external redirects. */
export function signInDestination(search: string): string {
  const next = new URLSearchParams(search).get("next");
  if (!next) return "/account";
  const base = "https://swiftterm.invalid";
  try {
    const url = new URL(next, base);
    return url.origin === base && url.pathname === "/live/"
      ? url.pathname + url.search + url.hash
      : "/account";
  } catch {
    return "/account";
  }
}
