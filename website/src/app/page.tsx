import Image from "next/image";
import Link from "next/link";

import { Logo } from "@/components/logo";

const HERO_LINKS = [
  { href: "/#how", label: "How it works" },
  { href: "/account", label: "Devices" },
];

/**
 * The landing page.
 *
 * The hero is a wallpaper card with the nav drawn *inside* it — the same construction as
 * aside-clone's: a floating pill over the artwork, a centred serif headline, one call to action,
 * and the real app screenshot rising out of the bottom of the card.
 *
 * The screenshot is a genuine capture of swiftTerm rather than the markup frame this page used to
 * draw. The frame was always a stand-in for a renderer nobody could see yet; now that the app is
 * real, the capture is the more honest of the two.
 */
export default function HomePage() {
  return (
    <>
      <div className="p-2 pb-0! md:p-4">
        <div
          className="relative overflow-hidden rounded-2xl bg-muted bg-cover bg-center shadow-xl md:rounded-3xl"
          style={{ backgroundImage: "url(/swiftterm/wallpaper.webp)" }}
        >
          {/* The nav lives in the card, so it floats on the artwork instead of sitting above it. */}
          <nav className="relative z-30 px-3 pt-3 md:px-4 md:pt-4">
            <div className="mx-auto flex h-12 w-full max-w-5xl items-center justify-between gap-3 rounded-full border border-white/50 bg-white/70 pr-1.5 pl-4 shadow-sm backdrop-blur-xl">
              <Link href="/" className="flex items-center">
                <Logo />
              </Link>

              <ul className="hidden items-center gap-1 md:flex">
                {HERO_LINKS.map((link) => (
                  <li key={link.href}>
                    <Link
                      href={link.href}
                      className="block rounded-full px-3 py-1.5 text-sm text-foreground/70 transition-colors hover:bg-foreground/5 hover:text-foreground"
                    >
                      {link.label}
                    </Link>
                  </li>
                ))}
              </ul>

              <div className="flex items-center gap-1.5">
                <Link
                  href="/sign-in"
                  className="rounded-full px-3 py-1.5 text-sm text-foreground/70 transition-colors hover:bg-foreground/5 hover:text-foreground"
                >
                  Log in
                </Link>
                <Link
                  href="/#how"
                  className="rounded-full bg-primary px-3.5 py-1.5 text-sm text-primary-foreground transition-opacity hover:opacity-90"
                >
                  Download
                </Link>
              </div>
            </div>
          </nav>

          <header className="relative z-1 px-6 pt-12 pb-9 text-center md:pt-16 md:pb-12">
            <h1 className="font-display mx-auto max-w-2xl text-4xl leading-[1.08] font-normal! tracking-[-0.01em] text-foreground md:text-6xl">
              Your terminal,
              <br />
              in the browser
            </h1>
            <p className="mx-auto mt-5 mb-8 max-w-md text-base text-foreground/70 md:text-lg">
              Share a live view of one terminal pane, and hand over control only while you are
              watching. The shell keeps running on your Mac — SwiftTerm never moves it.
            </p>
            <Link
              href="/sign-in"
              className="inline-flex h-10 items-center rounded-full bg-primary px-5 text-base text-primary-foreground transition-opacity hover:opacity-90"
            >
              Download for macOS
            </Link>
          </header>

          <div className="relative z-1 px-3 pb-3 md:px-6 md:pb-6">
            <Image
              src="/swiftterm/hero.webp"
              alt="swiftTerm running a shell over a wallpaper, the mark drawn in the terminal"
              width={2200}
              height={1382}
              priority
              sizes="(max-width: 768px) 100vw, 1400px"
              className="w-full rounded-xl shadow-2xl"
            />
          </div>
        </div>
      </div>

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
