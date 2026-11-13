---
description: Show the Huddle office status and pending decisions
---

Run `pwsh -NoProfile -File scripts/office-brief.ps1` and present the result following the "Office (Huddle)" rules in CLAUDE.md.

For each pending decision listed, read its `decisions/<n>.md` file and summarize the question in one line.
This command is read-only: do not change any work item state while answering it.
