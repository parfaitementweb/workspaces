---
description: Create an isolated workspace (worktree + Herd + DB) and open a new agent session in it
argument-hint: <branch|pr:N> [--from <branch>] [--secure] [--fresh] [--agent <cmd>]
allowed-tools: Bash(ws:*)
---

Create a new isolated workspace for this project and open a fresh agent session in it, in a new terminal tab.

Run exactly this command with the Bash tool (use a 600000 ms timeout — dependency sync can take a while the first time):

```bash
ws create $ARGUMENTS --open
```

Rules:
- Run it from the current working directory (the project root or any of its worktrees); `ws` resolves the main repository itself.
- Do not modify anything in the current checkout — the workspace lives in `.worktrees/`.
- If the command fails because the workspace already exists, run `ws open <branch>` instead of recreating it.
- When it succeeds, report back the URL, branch, path and database name printed in the "Workspace ready!" summary, then stop. The new session is running in its own terminal tab; nothing else to do here.
