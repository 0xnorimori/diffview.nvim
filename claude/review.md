---
description: Address open review comments left in nvim (nrev)
---

Review comments live in a per-repo SQLite DB owned by the `nrev` CLI
(shipped inside the diffview.nvim plugin at `bin/nrev`; use plain `nrev`
if it is on PATH, otherwise `~/develop/norimori/ggfarmco/diffview.nvim/bin/nrev`).

1. Run `nrev list --json --status open` from the repo root.
2. If the list is empty, say so and stop.
3. Handle each comment by `type`:
   - `issue`, `suggestion`: change the code at `file` lines
     `line_start`-`line_end`. `line_text` is a snapshot of the commented
     line — if line numbers have drifted, locate the spot by content.
   - `question`: answer it in the resolve note; only change code if the
     answer requires it.
   - `note`, `praise`: no action needed.
4. After addressing a comment run:
   `nrev resolve <id> --note "<one line: what was done or the answer>"`
5. Never resolve a comment you did not address — leave it open and say why.
6. Finish with a short summary: one line per comment, id + what happened.
