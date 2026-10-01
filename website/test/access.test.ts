import assert from "node:assert/strict";
import { it } from "node:test";
import { signInDestination } from "../src/shared_session/access.ts";

it("retains the stream and invitation through sign-in", () => {
  const next = "/live/?s=stream#invite=secret";
  assert.equal(signInDestination(`?next=${encodeURIComponent(next)}`), next);
});
it("rejects external and unrelated sign-in destinations", () => {
  for (const next of ["//evil.test/live/", "https://evil.test/live/", "/account", "javascript:alert(1)"]) {
    assert.equal(signInDestination(`?next=${encodeURIComponent(next)}`), "/account");
  }
});
