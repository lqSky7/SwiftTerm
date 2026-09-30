import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";

import { Navbar } from "@/components/navbar";

import "./globals.css";

// Same faces as aside-clone, loaded through next/font so they are self-hosted and preloaded
// without the stale absolute font paths the clone carried.
const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
};

export const metadata: Metadata = {
  title: "SwiftTerm | Your terminal, in the browser",
  description:
    "Share a live view of one terminal pane, and hand over control only while you are watching.",
  applicationName: "SwiftTerm",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${geistSans.variable} ${geistMono.variable} antialiased`}>
      <body className="flex min-h-dvh flex-col">
        <Navbar />
        <main className="flex-1">{children}</main>
        <footer className="border-t border-border/40 px-4 py-6 sm:px-6 lg:px-12">
          <div className="mx-auto flex w-full max-w-6xl items-center justify-between text-xs text-muted-foreground">
            <span>SwiftTerm</span>
            <span>No AI. Your shell never leaves your machine.</span>
          </div>
        </footer>
      </body>
    </html>
  );
}
