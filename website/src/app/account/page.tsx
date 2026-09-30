"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import { currentAccount, endSession, listDevices, revokeDevice, type Account, type Device } from "@/auth/client";

/**
 * Account and device management.
 *
 * Only what B1A's website scope covers: who you are signed in as, the devices registered against
 * the account, and the two things you can do about them. Live session listing arrives with the
 * relay in B2A — this page deliberately does not pretend to show sessions that do not exist yet.
 */
export default function AccountPage() {
  const router = useRouter();
  const [account, setAccount] = useState<Account | null>(null);
  const [devices, setDevices] = useState<Device[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "signed-out">("loading");
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const me = await currentAccount();
    if (me === null) {
      setState("signed-out");
      return;
    }
    setAccount(me);
    try {
      setDevices(await listDevices());
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not load devices");
    }
    setState("ready");
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function onRevoke(id: string) {
    setError(null);
    try {
      await revokeDevice(id);
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not revoke that device");
    }
  }

  async function onSignOut() {
    setError(null);
    try {
      await endSession();
      router.push("/");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not sign out");
    }
  }

  if (state === "loading") {
    return (
      <section className="mx-auto w-full max-w-2xl px-4 py-20 sm:px-6">
        <p className="text-sm text-muted-foreground">Loading…</p>
      </section>
    );
  }

  if (state === "signed-out") {
    return (
      <section className="mx-auto w-full max-w-2xl px-4 py-20 sm:px-6">
        <h1 className="text-2xl font-medium tracking-tight">Not signed in</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          There is no session for this browser. Sign in to see your account and devices.
        </p>
        <button
          type="button"
          onClick={() => router.push("/sign-in")}
          className="mt-6 rounded-lg bg-primary px-4 py-2.5 text-sm font-medium text-primary-foreground transition-opacity hover:opacity-90"
        >
          Sign in
        </button>
      </section>
    );
  }

  return (
    <section className="mx-auto w-full max-w-2xl px-4 py-16 sm:px-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-medium tracking-tight">
            {account?.display_name !== undefined && account.display_name !== ""
              ? account.display_name
              : "Your account"}
          </h1>
          <p className="mt-1 font-mono text-xs text-muted-foreground">{account?.id}</p>
        </div>
        <button
          type="button"
          onClick={onSignOut}
          className="rounded-lg border border-border px-3.5 py-1.5 text-sm font-medium transition-colors hover:bg-accent"
        >
          Sign out
        </button>
      </div>

      {error !== null && (
        <p role="alert" className="mt-6 text-sm text-destructive">
          {error}
        </p>
      )}

      <h2 className="mt-12 text-sm font-medium">Registered devices</h2>
      <p className="mt-1 text-xs text-muted-foreground">
        Each device holds its own credential. Revoking one takes effect on its next request.
      </p>

      {devices.length === 0 ? (
        <p className="mt-6 rounded-lg border border-dashed border-border px-4 py-8 text-center text-sm text-muted-foreground">
          No devices yet. Register one from the SwiftTerm app.
        </p>
      ) : (
        <ul className="mt-6 divide-y divide-border rounded-lg border border-border">
          {devices.map((device) => (
            <li key={device.id} className="flex items-center justify-between gap-4 px-4 py-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-medium">{device.label}</p>
                <p className="mt-0.5 font-mono text-xs text-muted-foreground">
                  {device.id.slice(0, 8)} · registered {new Date(device.created_at).toLocaleDateString()}
                  {device.revoked_at !== null && " · revoked"}
                </p>
              </div>
              {device.revoked_at === null && (
                <button
                  type="button"
                  onClick={() => void onRevoke(device.id)}
                  className="shrink-0 rounded-lg border border-border px-3 py-1.5 text-xs font-medium transition-colors hover:bg-accent"
                >
                  Revoke
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
