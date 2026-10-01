/**
 * The keystroke translator.
 *
 * These are the rules that decide what a browser is allowed to ask the host to do, so they are
 * tested as rules rather than through a rendered component: a chord that reaches the host by a route
 * nobody intended is the failure this file exists to prevent.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { validateInputOperation } from "../../contracts/ts/wire.ts";
import { inputOperationFor, type KeyChord } from "../src/shared_session/keys.ts";

function chord(overrides: Partial<KeyChord> = {}): KeyChord {
  return { key: "", code: "", shift: false, control: false, alt: false, meta: false, ...overrides };
}

describe("keystrokes to input operations", () => {
  it("sends a composed character as text", () => {
    assert.deepEqual(inputOperationFor(chord({ key: "a", code: "KeyA" })), {
      kind: "text",
      text: "a",
    });
    // Shift is already applied by the browser, so the character is what the person meant.
    assert.deepEqual(inputOperationFor(chord({ key: "A", code: "KeyA", shift: true })), {
      kind: "text",
      text: "A",
    });
    assert.deepEqual(inputOperationFor(chord({ key: "é", code: "KeyE", alt: false })), {
      kind: "text",
      text: "é",
    });
  });

  it("identifies a letter by its physical key, not by the character it produced", () => {
    // Option-a on a Mac reports `key: "å"`. Reading the letter off `key` would be the
    // keyboard-layout guess the contract forbids; `code` is the key that was actually pressed.
    const operation = inputOperationFor(
      chord({ key: "å", code: "KeyA", alt: true, control: false }),
    );
    assert.deepEqual(operation, { kind: "key", key: "a", modifiers: ["alt"] });
  });

  it("names the keys the contract names", () => {
    assert.deepEqual(inputOperationFor(chord({ key: "Enter", code: "Enter" })), {
      kind: "key",
      key: "enter",
      modifiers: [],
    });
    assert.deepEqual(inputOperationFor(chord({ key: "PageDown", code: "PageDown" })), {
      kind: "key",
      key: "page_down",
      modifiers: [],
    });
    assert.deepEqual(
      inputOperationFor(chord({ key: "ArrowUp", code: "ArrowUp", shift: true })),
      { kind: "key", key: "arrow_up", modifiers: ["shift"] },
    );
  });

  it("spells a chord's modifiers in the contract's order", () => {
    // The order is fixed so two ends cannot disagree about the spelling of the same chord, and the
    // contract's declaration order is shift, control, alt, meta.
    const operation = inputOperationFor(
      chord({ key: "c", code: "KeyC", control: true, shift: true, alt: true }),
    );
    assert.deepEqual(operation, {
      kind: "key",
      key: "c",
      modifiers: ["shift", "control", "alt"],
    });
  });

  it("keeps Control for the terminal and leaves Command to the browser", () => {
    // Ctrl-C must stay the interrupt. It is the one chord the contract singles out, and a browser
    // that turned it into a copy would be sending something else entirely.
    assert.deepEqual(inputOperationFor(chord({ key: "c", code: "KeyC", control: true })), {
      kind: "key",
      key: "c",
      modifiers: ["control"],
    });
    // Command belongs to the page: copy, paste, reload, the devtools. Stealing it would mean nobody
    // could copy from a terminal they are watching.
    assert.equal(inputOperationFor(chord({ key: "c", code: "KeyC", meta: true })), null);
    assert.equal(inputOperationFor(chord({ key: "Enter", code: "Enter", meta: true })), null);
  });

  it("drops a chord the union cannot express rather than guessing one", () => {
    // There is no raw-bytes case, so these have nowhere to go. Dropping them is the honest answer.
    assert.equal(inputOperationFor(chord({ key: "1", code: "Digit1", control: true })), null);
    assert.equal(inputOperationFor(chord({ key: "/", code: "Slash", control: true })), null);
    assert.equal(inputOperationFor(chord({ key: "Alt", code: "AltLeft", alt: true })), null);
  });

  it("produces only operations the contract accepts", () => {
    // The point of the whole file: whatever this returns must survive the validator, or the host
    // refuses a frame the browser was never entitled to send.
    const chords: KeyChord[] = [
      chord({ key: "a", code: "KeyA" }),
      chord({ key: "A", code: "KeyA", shift: true }),
      chord({ key: "c", code: "KeyC", control: true }),
      chord({ key: "z", code: "KeyZ", control: true }),
      chord({ key: "å", code: "KeyA", alt: true }),
      chord({ key: "Enter", code: "Enter" }),
      chord({ key: "Tab", code: "Tab" }),
      chord({ key: "Escape", code: "Escape" }),
      chord({ key: "F5", code: "F5" }),
      chord({ key: "ArrowLeft", code: "ArrowLeft", control: true }),
      chord({ key: "é", code: "KeyE" }),
    ];
    for (const candidate of chords) {
      const operation = inputOperationFor(candidate);
      assert.notEqual(operation, null, `${candidate.key} produced nothing`);
      if (operation === null) continue;
      // Throws when the operation is not one the contract allows.
      validateInputOperation(operation);
    }
  });

  it("refuses a NUL rather than sending a frame the host would reject", () => {
    assert.equal(inputOperationFor(chord({ key: "\u0000", code: "Space" })), null);
  });
});
