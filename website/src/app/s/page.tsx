import type { Metadata } from "next";
import { StaticShareViewer } from "@/sharing/viewer";
export const metadata: Metadata = { title: "Terminal snapshot | SwiftTerm", robots: { index: false, follow: false }, referrer: "no-referrer" };
export default function StaticSharePage() { return <StaticShareViewer />; }
