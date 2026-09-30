# Code review

Native right sidebar and coordinator. Uses shared crates/git reads. One selected bounded diff; file-level staging. No GitHub network integration.

Review width and the file-list/diff split are draggable, bounded per window. Reads stay cached during resizing.

Diff number gutters fit the largest displayed old/new line number, align right, and hide an
unused side for new/deleted files. Width is recomputed once per document, never while scrolling.
