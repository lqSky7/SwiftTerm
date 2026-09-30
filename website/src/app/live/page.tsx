"use client";

/**
 * The share route.
 *
 * The session id is a **query parameter**, not a path segment, and that is forced by how this site
 * is deployed: it is a static export, so every route is a file that exists at build time and a
 * dynamic `/live/<uuid>` segment would need the ids enumerated ahead of time. A query string needs
 * nothing built.
 *
 * The page is wrapped in `Suspense` because `useSearchParams` opts a page out of static rendering;
 * without the boundary the exporter refuses to build it rather than silently shipping a page that
 * renders empty.
 */

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";

import { LiveViewer } from "@/shared_session/viewer";

export default function LivePage() {
  return (
    <Suspense
      fallback={
        <div className="mx-auto w-full max-w-5xl px-6 py-8">
          <p className="text-sm text-muted-foreground" role="status" aria-live="polite">
            Loading…
          </p>
        </div>
      }
    >
      <LiveRoute />
    </Suspense>
  );
}

function LiveRoute() {
  const params = useSearchParams();
  return <LiveViewer sessionId={params.get("s")} />;
}
