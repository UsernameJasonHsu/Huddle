# gate-guard manual verification (T3)

The Pester suite proves the classifier and the hook wrapper. This checklist proves that Claude Code actually
calls the hook. Run it in a **new** Claude Code session started inside this repo:

```powershell
cd C:\Users\jason\Supervisor-Agent
claude
```

Every command below is harmless even if the gate does not engage: they only print text.
Ask Claude to run each one exactly as written, once with the Bash tool and once with the PowerShell tool.

| # | Command | Expected |
|---|---|---|
| 1 | `git status --short` | Runs normally (not gated) |
| 2 | `echo "harmless test: glab issue note 1 -m hi"` | **Blocked**, with a reason that starts with `[gate-guard] Agents must not comment on issues` |
| 3 | `echo "harmless test: git push"` | **Confirmation prompt** whose reason starts with `[gate-guard] git push writes to a remote` (choose No) |
| 4 | `echo "harmless test: git -C . push"` | Confirmation prompt (choose No) |

Then repeat #2 and #3 in every permission mode you plan to run Huddle in (default, and auto mode if you use it):

| Mode | #2 blocked? | #3 prompts? |
|---|---|---|
| default | Yes (Bash + PowerShell) | Yes (Bash + PowerShell; answered No) — verified 2026-11-05 |
| auto | Yes (Bash + PowerShell) | Yes (Bash + PowerShell; #4 also prompted) — verified 2026-11-05 |

If #3 does **not** prompt in some mode, Huddle must not run in that mode. Record that in `CLAUDE.md`
(T3 acceptance criterion).

If #2 is not blocked at all, check `/hooks` for the PreToolUse entry, and check that the session was
started inside this repo.
