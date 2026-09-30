import Link from "next/link";

/**
 * The landing page. The hero is a terminal frame drawn in markup rather than a screenshot, so it
 * stays in the achromatic token set and never goes stale against the real renderer.
 */
export default function HomePage() {
  return (
    <>
      <section className="mx-auto w-full max-w-6xl px-4 pt-20 pb-16 sm:px-6 lg:px-12">
        <div className="mx-auto max-w-3xl text-center">
          <h1 className="text-4xl leading-tight font-medium tracking-tight md:text-5xl">
            Your terminal, in the browser
          </h1>
          <p className="mt-5 text-base text-muted-foreground md:text-lg">
            Share a live view of one terminal pane, and hand over control only while you are
            watching. The shell keeps running on your Mac — SwiftTerm never moves it.
          </p>
          <div className="mt-8 flex items-center justify-center gap-3">
            <Link
              href="/sign-in"
              className="rounded-lg bg-primary px-5 py-2.5 text-sm font-medium text-primary-foreground transition-opacity hover:opacity-90"
            >
              Sign in
            </Link>
            <Link
              href="/#how"
              className="rounded-lg border border-border px-5 py-2.5 text-sm font-medium transition-colors hover:bg-accent"
            >
              How it works
            </Link>
          </div>
        </div>

        <div className="mx-auto mt-14 max-w-3xl overflow-hidden rounded-xl border border-border bg-card">
          <div className="flex items-center gap-1.5 border-b border-border px-4 py-3">
            <span className="size-2.5 rounded-full bg-muted-foreground/30" />
            <span className="size-2.5 rounded-full bg-muted-foreground/30" />
            <span className="size-2.5 rounded-full bg-muted-foreground/30" />
            <span className="ml-3 text-xs text-muted-foreground">shared pane</span>
          </div>
          <div className="terminal-cell px-4 py-4 text-[13px] leading-6">
            <p className="text-muted-foreground">$ deploy --env production</p>
            <p>building…</p>
            <p>uploading 34 files</p>
            <p className="text-foreground">
              ready<span className="ml-1 inline-block h-4 w-2 translate-y-0.5 bg-foreground" />
            </p>
          </div>
        </div>
      </section>

      <section id="how" className="border-t border-border/40">
        <div className="mx-auto grid w-full max-w-6xl gap-8 px-4 py-16 sm:px-6 md:grid-cols-3 lg:px-12">
          {[
            {
              title: "One pane, explicitly",
              body: "You choose the pane to share from the Mac app. Nothing is captured before you press start, and nothing is captured after you stop.",
            },
            {
              title: "Watch, then allow",
              body: "Viewing needs a link. Typing needs a lease the host approves, and your own keyboard takes it back the moment you touch it.",
            },
            {
              title: "Never in the dark",
              body: "An input the host has not acknowledged is shown as uncertain. Nothing is retried behind your back, so a command never runs twice.",
            },
          ].map((item) => (
            <div key={item.title}>
              <h2 className="text-base font-medium">{item.title}</h2>
              <p className="mt-2 text-sm leading-6 text-muted-foreground">{item.body}</p>
            </div>
          ))}
        </div>
      </section>
    </>
  );
}
