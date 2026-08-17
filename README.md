# ws — Workspace manager for Laravel + AI coding agents

Creates isolated workspaces via `git worktree`, with automatic setup of Laravel Herd, database, dependencies, and an agent session (Claude Code by default) — in seconds, thanks to APFS copy-on-write and database cloning.

Goal: from any project, run one command and get a fresh, fully working copy of the app (own URL, own DB, own Vite port, own cache namespace) with an agent running in it, so several sessions can work on the same project in parallel without stepping on each other.

Inspired by [Polyscope](https://getpolyscope.com/) and [laravel-herd-worktree](https://github.com/harris21/laravel-herd-worktree), with no third-party app dependency. `ws` is the Laravel-aware plumbing; it also plugs into Polyscope and Claude Code's native `--worktree` (see [Integrations](#integrations)).

## Quick usage

```bash
cd ~/Sites/my-project

ws create feat/auth --open        # workspace + new terminal tab running the agent   (~30 s)
ws create pr:42                   # review a GitHub PR in a full isolated environment
ws status                         # list workspaces, dirty flag, DB / Herd state, URLs
ws open feat/auth                 # (re)open the agent in a new tab
ws run feat/auth -- --resume      # launch the agent here, pass args through
ws preview feat/auth              # open http(s)://my-project-feat-auth.test
ws finish feat/auth               # PR / merge / abandon, then cleanup
ws destroy feat/auth              # remove worktree, DB, Herd link, branch
```

Inside a Claude Code session: `/workspace feat/auth` — same as `ws create feat/auth --open`.

Cheat sheet:

| Command | What it does |
|---|---|
| `ws create <branch\|pr:N> [--secure] [--fresh] [--open] [--agent <cmd> -- args]` | Create a workspace (HTTPS, empty DB, open agent, other agent) |
| `ws setup [--from <repo>] [--name <site>] [--standalone]` | Provision the current checkout (worktree, Polyscope clone...) |
| `ws run [branch] [--agent <cmd>] [-- args]` | Launch the agent in the workspace |
| `ws open [branch] [--agent <cmd>] [-- args]` | Same, in a new terminal tab/window |
| `ws status` | Overview of all workspaces |
| `ws preview [branch]` | Open the site in the browser |
| `ws finish [branch]` | Guided PR / merge / abandon |
| `ws destroy <branch> [--keep-db] [--yes]` | Delete everything |
| `ws hook create\|remove` | Adapter for Claude Code `WorktreeCreate` / `WorktreeRemove` hooks |

## Installation

Clone the repo and create a symlink:

```bash
git clone git@github.com:parfaitementweb/workspaces.git /path/to/workspaces
sudo ln -s /path/to/workspaces/ws /usr/local/bin/ws
```

Since it's a symlink, a `git pull` in the repo will update the `ws` command everywhere.

Optional — the `/workspace` slash command for Claude Code:

```bash
ln -s /path/to/workspaces/claude/commands/workspace.md ~/.claude/commands/workspace.md
```

Then, inside any Claude Code session: `/workspace feat/auth` creates the workspace and opens a new agent session in a new terminal tab.

> Replace `/path/to/workspaces` with the actual location of the cloned repo on your machine.

## Prerequisites

- **Git** (git worktree)
- **Laravel Herd** installed and in PATH
- **Composer** and **npm**
- An agent CLI in PATH — **Claude Code** (`claude`) by default, or any other (`codex`, `cursor-agent`, ...)
- **jq** or **python3** (for `.ws.json`)
- **gh** (optional, for creating PRs from `ws finish`)
- macOS on APFS for copy-on-write cloning (falls back to a regular install elsewhere)

## Usage

From the root of a Laravel project:

```bash
cd ~/Sites/my-project
```

### Create a workspace

```bash
ws create feature/auth            # HTTP by default
ws create feature/auth --open     # ...and open the agent in a new terminal tab when ready
ws create feature/auth --secure   # HTTPS (herd secure)
ws create feature/auth --fresh    # empty DB + migrate + seed instead of cloning the main DB
ws create pr:42                   # check out GitHub PR #42 in a worktree
ws create feature/auth --open --agent codex -- --model o3   # other agent, extra args after --
```

Everything is handled automatically:
- Creates a git worktree in `.worktrees/my-project-feature-auth/`
- Copies `.env` from the main project
- Updates `APP_URL`, `SESSION_DOMAIN`, `SANCTUM_STATEFUL_DOMAINS`, `SESSION_SECURE_COOKIE`
- Assigns a unique `VITE_PORT` (deterministic per branch, avoids `npm run dev` collisions)
- Namespaces shared services: `CACHE_PREFIX` / `REDIS_PREFIX` (when Redis or Memcached is used), `HORIZON_PREFIX`, `SCOUT_PREFIX`
- Clones `vendor/` and `node_modules/` from the main project with copy-on-write, then syncs only if the lockfile differs
- Clones the database (`myproject_feature_auth`) from the main one — PostgreSQL `TEMPLATE`, `mysqldump`, or SQLite file copy — then runs migrations. `--fresh` creates an empty DB and runs migrations + seeders instead
- Clones `storage/app` (uploads) and runs `storage:link`
- Copies `.claude/settings.local.json` and `CLAUDE.local.md` so agent permissions carry over
- Links with Herd → `http(s)://my-project-feature-auth.test`
- Patches Vite config (`host: 'localhost'`, `cors: true`, `port: Number(process.env.VITE_PORT) || 5173`) — commit that change once on your base branch so future workspaces start clean
- Clears Laravel caches
- Runs your `pre-create` / `post-create` hooks

Typical timing on a large Laravel app (380 MB vendor, 1 GB PostgreSQL DB): **~35 s**, most of it the DB clone.

**PR checkout** (`ws create pr:N`) fetches `pull/N/head` into a local branch `pr-N` via `gh` and creates a worktree on it — ideal for reviewing a PR in a full Laravel environment (isolated DB, Herd link, dependencies).

### Launch the agent in a workspace

```bash
ws run feature/auth              # launches the agent in the worktree (current terminal)
ws run                           # from a worktree: right here; from the root: interactive choice
ws run feature/auth -- --resume  # extra args are passed to the agent
ws run --agent codex             # any agent CLI

ws open feature/auth             # same, but in a NEW terminal tab/window
```

`ws open` (and `ws create --open`) spawns the agent in a new tab so the current session keeps running. Backend is auto-detected — tmux (when inside tmux), iTerm2, Terminal.app, Ghostty — or forced with `WS_TERMINAL=tmux|iterm|terminal|ghostty|none` / `"terminal"` in `.ws.json`.

The agent is `claude` by default; override with `--agent`, `WS_AGENT`, or `"agent"` in `.ws.json`.

### Provision an existing checkout

```bash
ws setup                                   # inside a worktree of the main repo
ws setup --from ~/Sites/my-project         # inside a clone/copy of the project (e.g. Polyscope)
ws setup --from ~/Sites/my-project --name "$(basename "$PWD")"   # Herd site named after the folder
```

`ws setup` runs the exact same provisioning as `ws create` (env, deps, DB, Herd, hooks) on the current directory, whatever created it. The source repository is auto-detected for git worktrees; for full clones pass `--from`. `--standalone` provisions with no source (uses `.env.example`, no hooks/`.ws.json`).

### View workspace status

```bash
ws status
```

```
my-project — Workspaces

  my-project-feature-auth  (feature/auth) ●  +3  ✓ DB  ✓ Herd  → https://my-project-feature-auth.test
  my-project-fix-header    (fix/header)      +1  ✓ DB  ✓ Herd  → http://my-project-fix-header.test
```

The yellow `●` indicates uncommitted changes.

### Open the site in the browser

```bash
ws preview feature/auth
ws preview                 # from a worktree
```

Automatically detects whether the site is HTTP or HTTPS.

### Finish work

```bash
ws finish                  # guided workflow
ws finish feature/auth     # specific workspace
```

Three options:
1. **Create a PR** — commit, push, `gh pr create` (recommended)
2. **Merge locally** — `git merge --no-commit --no-ff` for review
3. **Abandon** — deletes everything

### Delete a workspace

```bash
ws destroy feature/auth              # deletes everything (DB included)
ws destroy feature/auth --keep-db    # keeps the database
ws destroy feature/auth --yes        # no confirmation prompt
```

Deletes the worktree, local branch, database, Herd link(s), and SSL certificate if applicable. Use `--keep-db` to keep the database. The main project's database is never dropped.

## Integrations

### Claude Code `--worktree`

Claude Code can create worktrees itself (`claude -w feat/auth`) and exposes `WorktreeCreate` / `WorktreeRemove` hooks that replace its default git behaviour. `ws hook` is a drop-in adapter — add this to `~/.claude/settings.json` (or the project's `.claude/settings.json`), see [`claude/settings.hooks.example.json`](claude/settings.hooks.example.json):

```json
{
  "hooks": {
    "WorktreeCreate": [ { "hooks": [ { "type": "command", "command": "ws hook create" } ] } ],
    "WorktreeRemove": [ { "hooks": [ { "type": "command", "command": "ws hook remove" } ] } ]
  }
}
```

`claude -w feat/auth` then produces a full `ws` workspace, and it is torn down (DB, Herd link, branch) when the session ends — unless it has uncommitted changes, in which case it is kept, exactly like Claude's own behaviour.

Note the different lifecycle: `-w` workspaces are tied to the session; `ws create` workspaces persist until `ws finish` / `ws destroy`. Both are fine — pick per task.

### Polyscope

Polyscope clones the whole project folder with copy-on-write and runs a setup script; `ws setup` is that script. In `polyscope.json`:

```json
{
  "scripts": {
    "setup": "ws setup --from /path/to/my-project --name \"$(basename \"$PWD\")\"",
    "archive": "herd unlink \"$(basename \"$PWD\")\""
  },
  "preview": { "url": "http://{{folder}}.test" }
}
```

### Other agents

Nothing in `ws` is Claude-specific except the default agent name. `ws run --agent codex`, `WS_AGENT=cursor-agent`, or `"agent": "..."` in `.ws.json`.

## Hooks

Drop executable scripts in `.ws/hooks/` at the repo root to run custom logic on workspace lifecycle events:

| Hook | When it runs |
|---|---|
| `pre-create` | Worktree created, before dependencies install |
| `post-create` | `ws create` finished, everything set up |
| `pre-destroy` | Before `ws destroy` removes anything |
| `post-finish` | After `ws finish` (PR / merge / abandon) |

The following variables are exported to hooks:

| Variable | Value |
|---|---|
| `WS_EVENT` | Hook name (`post-create`, `pre-destroy`, ...) |
| `WS_PROJECT` | Main project name |
| `WS_BRANCH` | Branch name |
| `WS_SITE` | Slug used for the Herd site / worktree dir |
| `WS_DIR` | Absolute path to the worktree |
| `WS_URL` | Full URL (`http(s)://…test`) |
| `WS_DB` | Workspace database name (if Laravel + DB detected) |
| `WS_ROOT` | Absolute path to the main repo |

Example `.ws/hooks/post-create`:

```bash
#!/usr/bin/env bash
set -e
cd "$WS_DIR"
php artisan db:seed --class=DemoSeeder --no-interaction || true
php artisan horizon:terminate 2>/dev/null || true
echo "✔ workspace $WS_BRANCH ready at $WS_URL"
```

Don't forget `chmod +x .ws/hooks/post-create`. Hooks are optional — if a file is missing or not executable, `ws` silently skips it.

## Configuration (`.ws.json`)

Optional file at the repo root:

```json
{
  "agent": "claude",
  "terminal": "iterm",
  "domain": "APP_DOMAIN",
  "subdomains": {
    "admin": "FILAMENT_DOMAIN",
    "api": "API_DOMAIN"
  }
}
```

| Key | Purpose |
|---|---|
| `agent` | Agent CLI launched by `ws run` / `ws open` (default `claude`). Env override: `WS_AGENT` |
| `terminal` | `tmux` \| `iterm` \| `terminal` \| `ghostty` \| `none` (default: auto). Env override: `WS_TERMINAL` |
| `domain` | Env var holding the project's main host, patched to `<project>-<branch>.test` |
| `subdomains` | Map of `prefix → env_var`. Each entry adds a `herd link` (`admin.<project>-<branch>.test`), patches the env var, is added to `SANCTUM_STATEFUL_DOMAINS`, and switches `SESSION_DOMAIN` to `.<project>-<branch>.test` so cookies span all hosts |

With `--secure`, each subdomain is also passed through `herd secure`. `ws destroy` cleans up every subdomain link as long as `.ws.json` is still present at the repo root.

## Naming

Herd sites use the format `project-branch.test` to avoid conflicts between projects:

| Project | Branch | Herd Site |
|---|---|---|
| `my-app` | `feature/login` | `my-app-feature-login.test` |
| `other-app` | `feature/login` | `other-app-feature-login.test` |

## Structure

```
my-project/
├── .worktrees/                          # ignored by git
│   ├── my-project-feature-auth/         # isolated worktree
│   │   ├── .env                         # APP_URL, DB, session configured
│   │   ├── vendor/                      # dedicated composer install
│   │   └── node_modules/               # dedicated npm install
│   └── my-project-fix-header/
├── app/
├── composer.json
└── ...
```

## .env auto-configuration

| Variable | Value |
|---|---|
| `APP_URL` | `http(s)://project-branch.test` |
| `DB_DATABASE` | `original_db_branch_slug` |
| `SESSION_DOMAIN` | `project-branch.test` (`.project-branch.test` with subdomains) |
| `SANCTUM_STATEFUL_DOMAINS` | Domain + subdomains appended (if Sanctum detected) |
| `SESSION_SECURE_COOKIE` | `true` if --secure, `false` otherwise |
| `VITE_PORT` | Deterministic port in 5173–6172 |
| `CACHE_PREFIX`, `REDIS_PREFIX` | `project_branch_…` (only when Redis/Memcached is used) |
| `HORIZON_PREFIX` | `project_branch_horizon:` (if Horizon installed) |
| `SCOUT_PREFIX` | `project_branch_` (if Scout installed) |
| `<domain>` / `<subdomains>` from `.ws.json` | `project-branch.test` / `prefix.project-branch.test` |

Names longer than 60 chars are truncated with a short hash to stay within hostname / database-name limits.

## Troubleshooting

### 401 on API routes
The worktree domain is not in `SANCTUM_STATEFUL_DOMAINS`. Normally configured automatically. Try `php artisan config:clear`.

### Cookies rejected
`SESSION_DOMAIN` doesn't match the Herd domain. Check the worktree `.env`.

### Blank page / CORS errors
Check that `vite.config.js` has `host: 'localhost'` and `cors: true`. Kill existing Vite processes: `pkill -f "node.*vite"`.

### Mixed Content (HTTPS)
If the site is secured with Herd, make sure `APP_URL` is `https://`. Use `ws create <branch> --secure`.

### Assets not loading
```bash
pkill -f "node.*vite"
rm -f public/hot
npm run dev
```

### Migrations failed
The worktree database might not exist. Check `DB_DATABASE` in `.env` and create the database manually if needed.

### DB clone is slow / falls back to pg_dump
PostgreSQL `TEMPLATE` cloning needs no open connections on the source database — close Herd's DB clients / queue workers, or accept the `pg_dump` fallback. Use `--fresh` to skip cloning entirely.

### Jobs / cache leaking between workspaces
Only Redis and Memcached are namespaced automatically. If you use another shared service (Meilisearch without Scout, Typesense, Mailpit tags...), add its prefix in a `post-create` hook.

## License

MIT
