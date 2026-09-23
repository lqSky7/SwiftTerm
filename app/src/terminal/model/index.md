# app/src/terminal/model — index

Empty, and now deliberately so. The block model went to
`crates/warp_terminal/src/model/` instead: a block owns grids, so it is part of the emulator's own
vocabulary rather than something the application layers on top.

This folder is for a model that is genuinely feature-level — something that only makes sense once
there is an application around it, and that the emulator crate has no business knowing about. Phase 3
is the first candidate: the command editor's buffer is the application's, not the emulator's.
