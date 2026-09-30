# Frozen v1 wire shapes for C0

Refines protocol.md; no implementation yet. New wire fields require updating this file, both DTO
sets and fixtures together. No arbitrary JSON bags. Objects reject extra properties. All UUIDs
are canonical lowercase strings; counters are decimal strings matching `0|[1-9][0-9]{0,18}` and
<=signed Int64 max. Integers otherwise are JSON safe integers, nonnegative unless noted.
Epoch starts at 1; seq/input_seq start at 1; snapshot S may be 0. Time is UTC ISO8601 milliseconds.
Optional fields are omitted, not null. Any size/epoch/fullscreen transition uses a fresh snapshot.

## Colors, styles, rows

Color = `{kind:"palette",index:0..255}` OR `{kind:"rgb",r:0..255,g:0..255,b:0..255}`.
Style = `{fg:Color,bg:Color,flags:int}`; flags 0..255 bits bold/dim/italic/underline/blink/inverse/
hidden/strike in that order. No URLs/font names/HTML/CSS/OSC. Styles indexed 0..4095; index 0 is
default. Cell = `{text:string,width:0|1|2,style:int}`. Text one extended grapheme <=64 UTF-8 bytes;
width-0 continuation has empty text and follows a width-2 cell. No isolated continuation/wide cell
at last column. Row = array of exactly columns cells. Empty cells have text=" ", width=1.
Control characters except allowed grapheme joiners are rejected. Overflow stops stream with a
visible unsupported-state error; never resize/truncate host content silently.

Grid = `{lines:Row[],cursor:{row:int,column:int,visible:bool,shape:"block"|"underline"|"bar",blink:bool}}`.
Empty grids require cursor row/column zero and visible=false. Other cursor coordinates reference lines; all grids together <=2000 lines; columns/rows each 1..512.
Transport uses bounded visible/recent state, not the entire terminal history.

## Assembled snapshot JSON

Required fields: `{version:1,epoch:string,seq:string,mode:"blocks"|"fullscreen",columns:int,rows:int,
styles:Style[],blocks:Block[],viewport:Viewport,editor:Editor}`.
Block = `{id:uuid,command:string,state:"draft"|"running"|"sealed",collapsed:bool,
header:Grid,output:Grid}` with optional exit_code (signed Int32), duration_ms (nonnegative integer).
Command <=64 KiB UTF-8; <=50 blocks, unique UUIDs. Omit cwd/hostname/environment/Git/sidebar and
hyperlinks in live v1. These can leak information and are not needed for cell render parity.
Viewport = `{first_block_id:uuid,first_line:int,pinned_block_id:uuid}`; referenced IDs must exist.
Grid content and collapse metadata let viewer reconstruct the same visible block window.
Editor = `{visible:bool,text:string,selection_start:int,selection_length:int}`; UTF-16 offsets must
be inside text, on scalar boundaries; text <=64 KiB UTF-8. Selection is draft selection only,
not native scrollback selection. Hidden editor has empty text and zero selection.
Fullscreen has exactly one active block, visible screen rows in output and editor.visible=false.
Snapshot assembled UTF-8 <=4 MiB. Encode deterministic sorted-key JSON; hash the raw UTF-8 bytes,
not a parsed/reencoded object. Cells/colors are already normalized, no VT interpretation in browser.

Frames: snapshot.begin `{type,epoch,seq,snapshot_id:uuid,bytes:int,chunks:int,sha256:hex64}`;
snapshot.chunk `{type,epoch,snapshot_id,index:int,data:base64}`; snapshot.end `{type,epoch,snapshot_id}`.
Raw chunk <=45 KiB, encoded frame <=64 KiB, chunks<=128, indexes zero-based contiguous. Browser
reassembles in bounded scratch buffer, verifies count/length/hash, swaps snapshot atomically.
Chunks from another ID/epoch or missing chunks abort assembly and request resync. No compression
in v1. Only one pending snapshot per socket; deltas above S follow snapshot.end in order.

## Damage

`{type:"damage",epoch,seq,base_seq,changes:Op[]}` <=128 ops and <=64 KiB serialized.
Op exact union:
- `{op:"insert_block",after_id?:uuid,block:Block}`; missing after_id inserts first.
- `{op:"remove_block",block_id:uuid}`; deleting unknown ID is an error, not a no-op.
- `{op:"replace_header",block_id:uuid,command:string,state:...,exit_code?:int,duration_ms?:int}`.
- `{op:"set_collapsed",block_id:uuid,collapsed:bool}`.
- `{op:"replace_row",block_id:uuid,grid:"header"|"output",row:int,cells:Row}`.
- `{op:"truncate_grid",block_id:uuid,grid:...,line_count:int}`.
- `{op:"set_cursor",block_id:uuid,grid:...,cursor:Grid.cursor}`.
- `{op:"replace_editor",editor:Editor}`.
- `{op:"replace_viewport",viewport:Viewport}`.

Rows can append only at current length; never create gaps. Apply one validated frame atomically.
Styles are fixed per snapshot; new styles, oversized damage, block-window replacement or geometry
changes trigger snapshot barrier. Seq increments per emitted damage frame; base_seq must equal
last applied seq, seq=base_seq+1. Same epoch duplicates <=last seq are ignored. Gaps request resync.

## Input and lifecycle

Existing auth/hello/resume/control protocol applies. Input operation exact union:
`{kind:"text",text:string}`, `{kind:"paste",text:string}`, `{kind:"key",key:enum,modifiers:enum[]}`,
`{kind:"undo"}`, `{kind:"redo"}`. Text/paste <=64 KiB UTF-8, no NUL; preserve CR/LF and do not add
Enter. Text is an IME committed insertion, never a keyboard-layout guess. Keys: Enter, Tab,
Backspace, Delete, Escape, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, F1..F12 and A..Z
for modified key chords. Modifiers: shift/control/alt/meta, unique; unsupported combinations reject.
No raw bytes/mouse/resize/shell commands. Prompt keys edit/submit using native actions; running/TUI
keys go through TerminalInput. Logical Ctrl-C always remains Ctrl-C, not an API cancellation call.

control.request `{type,epoch}` → host visible approval → control.granted `{type,epoch,lease:uuid,
expires_at:time}` or control.denied `{type,epoch}`. Lease connection-bound; requester cannot specify
another client. control.revoked `{type,epoch,lease,reason:"local_input"|"expired"|"disconnect"|
"revoked"|"ended"}` cancels pending browser input immediately. Heartbeats do not renew approval
past account/device/grant expiry. viewer.count `{type,epoch,count:int}` is relay→host only.

Input seq is per lease, not terminal output seq. Next only; duplicates may get cached admission ack,
gaps reject. Ack status applied/rejected with bounded code, never shell success. On transport loss
all unacked inputs are uncertain; do not retry. host reconnect begins new epoch and revokes control.
No frontend may acquire control merely by receiving a controller permission in HTTP JSON.

## Static shares

Use protocol.md sealed-block DTO: 20 blocks, <=2 MiB JSON, schema_version=1. Explicit line text and
allowlisted styles; spans `{start:int,length:int,style:int}` in UTF-16 offsets, ordered/nonoverlapping,
nonzero length and within line. Include snapshot-level Style[] using the same bounded styles above.
No live editor, raw grid controls, scripts, images, external links or active remote identifiers.
Directory defaults to abbreviated/redacted display label only after preview; never export full
absolute paths implicitly. Commands/text are escaped data. Snapshot UUIDs are export identities.

Capabilities: client generates/retains 32 random bytes, base64url without padding (43 chars),
server stores SHA-256 only. Share locator is a random UUID, secret goes in browser fragment;
website resolves via POST then removes fragment with replaceState and retains secret in memory,
not localStorage/service-worker caches. Restricted mode requires approved account AND capability,
except authenticated owner management preview. Revoked/expired/denied/missing uniformly 404.

## Remaining connection frames

- auth `{type:"auth",ticket:string,client_id:uuid}` <=4 KiB first frame, within 5 seconds.
- hello `{type:"hello",version:1,session_id:uuid,epoch,mode,columns,rows}` from relay to authenticated peer.
- resume `{type:"resume",epoch,seq}` from viewer; only current epoch may replay retained frames.
- resync `{type:"resync",epoch}` requests a fresh snapshot; host discards old queued damage at barrier.
- output.ack `{type:"output.ack",epoch,seq}` reports viewer-applied seq, not socket-send completion.
- error `{type:"error",code:string}` where code is an allowlisted protocol error, no raw diagnostics.
- input.ack `{type:"input.ack",epoch,control_lease:uuid,input_seq,status:"applied"|"rejected",code?:string}`.

Error/input rejection codes: unauthorized, unsupported_version, invalid_frame, stale_epoch,
stale_lease, input_gap, rate_limited, capacity, unsupported_input, session_ended, resync_required.
Reject frames from the wrong direction/role; viewer cannot send snapshot/damage/ack on host's behalf.
Malformed/oversized traffic closes the connection after a bounded error; do not buffer for recovery.
Transport Ping/Pong uses WebSocket control frames rather than JSON messages. Renewals/fences are
relay/host operations, never a browser-written lease timestamp.

## Frozen by C0

C0 implemented this file and had to decide the spellings and the cases it left open. Those decisions
are now part of the contract: the Swift DTOs in `crates/shared_session/src` and
`crates/cloud_objects/src`, the TypeScript validators in `contracts/ts/wire.ts`, and the shared
fixtures in `contracts/fixtures` all encode them. Changing any of them is a coordinated revision of
all four, not an implementation detail.

Enum spellings this file had named but not spelled:

| Enum | Wire values |
| --- | --- |
| `key` | `enter`, `tab`, `backspace`, `delete`, `escape`, `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `home`, `end`, `page_up`, `page_down`, `f1`…`f12`, `a`…`z` |
| `modifiers` | `shift`, `control`, `alt`, `meta` |
| frame direction | `host_to_relay`, `viewer_to_relay`, `relay_to_host`, `relay_to_viewer` |

Rules this file left implicit, now enforced by both implementations:

- **A letter key requires a control, alt or meta chord.** An unmodified letter is text, and a
  keyboard-layout guess is what "never a keyboard-layout guess" forbids.
- **A rejected `input.ack` must carry a code.** A silent rejection is the failure mode the
  acknowledgement exists to prevent.
- **An explicit JSON `null` is refused for an optional field.** Optional fields are omitted; a null
  is a peer that means something else.
- **An empty grid parks an invisible cursor at row 0, column 0.** Any other cursor in an empty grid
  is out of bounds.
- **Styles are a non-empty table and index 0 is the default.** Every cell's style index must be
  inside the table, so a renderer never falls back silently.
- **The whole snapshot is capped at 2000 grid lines** across all blocks, not per grid.
- **A snapshot is the only carrier of an epoch, a geometry or a mode change.** No damage operation
  resizes, and none changes mode. Applying a snapshot replaces every field at once.
- **A damage frame is applied atomically.** Operations check their own local preconditions;
  cursor placement, viewport references, style indices and the line budget are checked once per
  frame, so a frame may truncate a grid and move the cursor in the same message. A frame that fails
  anywhere leaves the view unchanged.
- **`seq` may be 0 in a snapshot and must be >= 1 in damage and input frames.** `epoch` and
  `input_seq` are always >= 1.
- **An export directory label may not be absolute, may not start with `~`, and may not contain a
  `..` component.** Abbreviating a real path silently is the implicit full-path export the
  contract forbids.
- **The share capability is 43 base64url characters, and the final character's low two bits are
  zero.** 32 bytes is 256 bits and 43 characters hold 258, so a larger final character is a second
  spelling of the same secret. The server stores the SHA-256 of the one spelling.

Where the two implementations and the fixtures live, and how to run both halves of the gate, is in
`contracts/index.md`.
