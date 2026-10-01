/**
 * A keystroke, as a browser reports it, turned into the contract's input union.
 *
 * A pure function over a plain object rather than over a `KeyboardEvent`, because the rules are the
 * part worth testing and `KeyboardEvent` does not exist outside a browser. The viewer's event
 * handler does the one thing this cannot: read the fields off the event.
 *
 * Four rules, and each is a decision:
 *
 *   * **A printable character is text, not a key.** The contract says a text insertion is an IME
 *     commitment and never a keyboard-layout guess, so the character the browser composed is sent as
 *     itself. Letters are the exception it makes explicitly: an unmodified letter is text.
 *   * **A letter is identified by `code`, not by `key`.** `code` is the physical key, so `⌥a` on a
 *     Mac — whose `key` is `å` — is still the letter `a`. Deriving the letter from `key` would be
 *     the layout guess the contract forbids.
 *   * **Command is the browser's.** `⌘C`, `⌘V`, `⌘R` and the devtools belong to the page the person
 *     is looking at, and stealing them would mean nobody could copy from a terminal they are
 *     watching. Control is forwarded, because the contract singles out Ctrl-C: a logical interrupt
 *     must stay an interrupt.
 *   * **Nothing is invented.** A chord the union cannot express — `⌃1`, `⌃/`, a bare `⌥` — returns
 *     null and is dropped. There is no raw-bytes case to fall back to, and guessing one would be
 *     sending something the host never agreed to receive.
 */

import type { WireInputKey, WireInputOperation, WireModifier } from "../../../contracts/ts/wire.ts";

export interface KeyChord {
  /** `KeyboardEvent.key` — the character or the named key the browser reports. */
  readonly key: string;
  /** `KeyboardEvent.code` — the physical key. Used for letters, which are layout-independent. */
  readonly code: string;
  readonly shift: boolean;
  readonly control: boolean;
  readonly alt: boolean;
  readonly meta: boolean;
}

/** The named keys, spelled the way `KeyboardEvent.key` spells them. */
const NAMED_KEYS: Record<string, WireInputKey> = {
  Enter: "enter",
  Tab: "tab",
  Backspace: "backspace",
  Delete: "delete",
  Escape: "escape",
  ArrowUp: "arrow_up",
  ArrowDown: "arrow_down",
  ArrowLeft: "arrow_left",
  ArrowRight: "arrow_right",
  Home: "home",
  End: "end",
  PageUp: "page_up",
  PageDown: "page_down",
  F1: "f1",
  F2: "f2",
  F3: "f3",
  F4: "f4",
  F5: "f5",
  F6: "f6",
  F7: "f7",
  F8: "f8",
  F9: "f9",
  F10: "f10",
  F11: "f11",
  F12: "f12",
};

/** In the contract's declared order, so two ends cannot disagree about the spelling of a chord. */
function modifiersOf(chord: KeyChord): WireModifier[] {
  const modifiers: WireModifier[] = [];
  if (chord.shift) modifiers.push("shift");
  if (chord.control) modifiers.push("control");
  if (chord.alt) modifiers.push("alt");
  if (chord.meta) modifiers.push("meta");
  return modifiers;
}

/** The letter a physical key stands for, or null when it is not a letter. */
function letterFor(code: string): WireInputKey | null {
  if (code.length !== 4 || !code.startsWith("Key")) return null;
  const letter = code.slice(3).toLowerCase();
  return letter >= "a" && letter <= "z" ? (letter as WireInputKey) : null;
}

export function inputOperationFor(chord: KeyChord): WireInputOperation | null {
  // Command is the browser's. Checked first, so no chord can reach the host by another route.
  if (chord.meta) return null;

  const named = NAMED_KEYS[chord.key];
  if (named !== undefined) {
    return { kind: "key", key: named, modifiers: modifiersOf(chord) };
  }

  const letter = letterFor(chord.code);
  if (letter !== null) {
    if (chord.control || chord.alt) {
      return { kind: "key", key: letter, modifiers: modifiersOf(chord) };
    }
    // A bare letter, or a shifted one. The browser already applied shift, so `key` is the character
    // the person meant and the contract wants it as text.
    return textFor(chord.key);
  }

  if (chord.control || chord.alt) {
    // Control or Option over a key the union has no name for. There is no raw-bytes case to send it
    // as, and inventing one would be a frame the host never agreed to receive.
    return null;
  }

  return textFor(chord.key);
}

function textFor(text: string): WireInputOperation | null {
  // A single composed character. Anything longer is a named key or an IME artifact, and a NUL is
  // refused by the contract outright.
  if (text.length === 0 || text.length > 2) return null;
  if (text.includes("\u0000")) return null;
  return { kind: "text", text };
}

/** Read a chord off a browser event. The only place that touches `KeyboardEvent`. */
export function chordFrom(event: KeyboardEvent): KeyChord {
  return {
    key: event.key,
    code: event.code,
    shift: event.shiftKey,
    control: event.ctrlKey,
    alt: event.altKey,
    meta: event.metaKey,
  };
}
