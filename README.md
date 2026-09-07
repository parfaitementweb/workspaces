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
| `ws create <branch\|pr:N> [--from <branch>] [--secure] [--fresh] [--plain] [--open] [--agent <cmd> -- args]` | Create a workspace (base branch, HTTPS, empty DB, no Laravel steps, open agent, other agent) |
| `ws setup [--from <repo>] [--name <site>] [--secure] [--fresh] [--plain] [--standalone]` | Provision the current checkout (worktree, Polyscope clone...) |
| `ws run [branch] [--agent <cmd>] [-- args]` | Launch the agent in the workspace |
| `ws open [branch] [--agent <cmd>] [-- args]` | Same, in a new terminal tab/window |
| `ws status` | Overview of all workspaces |
| `ws info [branch]` | One workspace: branch, base, commits ahead, URL, DB, test DB, Herd |
| `ws preview [branch]` | Open the site in the browser |
| `ws finish\|merge [branch] [--into <branch>] [--pr\|--merge\|--abandon] [--message\|-m <msg>] [--title <t>] [--cleanup]` | PR / merge / abandon against the base branch, guided or non-interactive |
| `ws destroy <branch> [--keep-db] [--yes\|-y]` | Delete everything |
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
- **Laravel Herd** installed (its `bin` directory is put first on the PATH, as Herd's own shell setup does, so `ws` resolves the same `herd`, `php` and `psql` from non-interactive shells). Without Herd, a Laravel project still gets its `.env`, database and Vite port; only the site link is skipped
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
ws create feature/auth --from develop   # branch off develop instead of the default branch
ws create pr:42                   # check out GitHub PR #42 in a worktree
ws create feature/auth --open --agent codex -- --model o3   # other agent, extra args after --
```

Everything is handled automatically:
- Creates a git worktree in `.worktrees/my-project-feature-auth/`, on a new branch cut from the repo default branch (`origin/HEAD`, else local `main` or `master`); the branch currently checked out in the main repo plays no part. Override with `--from <branch|tag|sha>`; a branch that already exists locally is checked out as-is and `--from` is ignored
- Copies `.env` from the main project
- Updates `APP_URL`, `SESSION_DOMAIN`, `SANCTUM_STATEFUL_DOMAINS`, `SESSION_SECURE_COOKIE`
- Assigns a unique `VITE_PORT` (deterministic per branch, avoids `npm run dev` collisions)
- Namespaces shared services: `CACHE_PREFIX` / `REDIS_PREFIX` (when Redis or Memcached is used), `HORIZON_PREFIX`, `SCOUT_PREFIX`
- Clones `vendor/` and `node_modules/` from the main project with copy-on-write, then syncs only if the lockfile differs
- Clones the database (`myproject_feature_auth`) from the main one — PostgreSQL `TEMPLATE`, `mysqldump`, or SQLite file copy — then runs migrations. `--fresh` creates an empty DB and runs migrations + seeders instead. A database that already exists under that name is kept as is (migrations only). SQLite keeps `DB_DATABASE` untouched: the file (default `database/database.sqlite`, relative to the worktree) is copied, an absolute path is left alone
- Isolates the test database (`test_myproject_feature_auth`): copies `.env.testing`, creates an empty DB, and points `phpunit.xml` at it so suites can run in parallel with the main repo without deadlocking
- Clones `storage/app` (uploads) and runs `storage:link`
- Copies `.claude/settings.local.json` and `CLAUDE.local.md` so agent permissions carry over
- Symlinks the gitignored files listed under `"files"` in `.ws.json` (local MCP configs, credentials...) to the main checkout
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

`ws setup` runs the exact same provisioning as `ws create` (env, deps, DB, Herd, hooks) on the current directory, whatever created it. Running it again is safe: an existing `.env`, `storage/app` clone and database are kept (`--fresh` replaces them). The source repository is auto-detected for git worktrees; for full clones pass `--from` or set `WS_SOURCE=/path/to/main-repo`. `--standalone` provisions with no source (uses `.env.example`, no hooks/`.ws.json`).

### View workspace status

```bash
ws status
```

```
my-project — Workspaces

  feature/auth ●  +3  ✓ DB  ✓ Herd  → https://my-project-feature-auth.test
  └─ → https://admin.my-project-feature-auth.test
  fix/header  +1  ✓ DB  – Herd  → http://my-project-fix-header.test
  docs/readme  +0  plain → /Users/me/Sites/my-project/.worktrees/my-project-docs-readme
  my-project-old-thing  stale (no git worktree, run: ws destroy my-project-old-thing)
```

The yellow `●` indicates uncommitted changes. Subdomains from `.ws.json` are listed under their site, `plain` workspaces show their path instead of a URL, and a `stale` line is a directory left in `.worktrees/` after its worktree was pruned.

```bash
ws info feature/auth       # one workspace: branch, base, commits ahead, URL, DB, test DB, Herd
ws info                    # from a worktree
```

### Open the site in the browser

```bash
ws preview feature/auth
ws preview                 # from a worktree
```

Automatically detects whether the site is HTTP or HTTPS.

### Finish work

```bash
ws finish                            # guided workflow
ws finish feature/auth               # specific workspace
ws finish feature/auth --into develop  # override the target branch
ws finish feature/auth --pr --cleanup  # no prompts: push, open the PR, delete the workspace
```

Three options:
1. **Create a PR** — commit, push, `gh pr create` against the base branch (recommended)
2. **Merge locally** — checks out the base branch in the main checkout, then `git merge --no-ff`: the merge is committed; on conflicts `ws` exits `1`, leaves the main checkout mid-merge, and you finish with `git commit` before running `ws finish` again
3. **Abandon** — deletes everything

The base branch is the one the workspace was created from (`--from`, or the repo default branch). It is recorded at creation time (`git config branch.<name>.ws-base`), so it does not depend on what happens to be checked out in the main repo later. Use `--into` to target another branch. `ws merge` is an alias of `ws finish`, and every value-taking option also accepts the `--option=value` form.

### Delete a workspace

```bash
ws destroy feature/auth              # deletes everything (DB included)
ws destroy feature/auth --keep-db    # keeps the database
ws destroy feature/auth --yes        # no confirmation prompt
```

Deletes the worktree, the database and the test database, the Herd link(s) and certificate if applicable, and kills the workspace's Vite dev server. The local branch is deleted only when it is merged (`git branch -d`); otherwise it is kept and a warning says so. Use `--keep-db` to keep the databases. Only databases named `<main database>_…` (the names `ws` creates) are ever dropped; a workspace `.env` pointing anywhere else is left alone. A stale directory (no git worktree behind it) is removed without touching any branch; a separate git repository dropped under `.worktrees/` is refused. Uncommitted changes in the worktree are listed in the confirmation and lost with it. `ws finish --abandon` deletes the branch even when it is not merged.

## Machine-readable output (`--json`)

Add `--json` to any command (`WS_JSON=1` in the environment is equivalent). Human output is unchanged without it. In JSON mode stdout carries JSON only: progress and the output of the tools `ws` calls go to stderr, errors are a single `{"error": "..."}` line on stderr, and no command ever prompts.

Exit codes: `0` success, or a confirmation declined at a prompt (nothing was done); `1` user error (bad usage, unknown workspace, missing `--message`); `2` environment error (no git repository, missing tool, git or push failure).

### Workspace record

`ws status --json` prints an array of records, `ws info <branch> --json` a single one:

```json
{
  "site": "my-project-feature-auth",
  "branch": "feature/auth",
  "path": "/Users/me/Sites/my-project/.worktrees/my-project-feature-auth",
  "base": "main",
  "dirty": true,
  "ahead": 3,
  "profile": "laravel-herd",
  "url": "https://my-project-feature-auth.test",
  "db": "my_project_feature_auth",
  "test_db": "test_my_project_feature_auth",
  "herd": true
}
```

`site`, `branch`, `path`, `base`, `dirty`, `ahead` (commits ahead of `base`) and `profile` are always present. `url`, `db`, `test_db` and `herd` are omitted, never `null`, when they do not apply: no `.env`, no test database, Herd not installed. `"stale": true` flags a directory left in `.worktrees/` without a git worktree behind it (`branch` is then `?`); `ws destroy` removes it.

### `ws create <branch> --json`

Streams NDJSON, one line per step, flushed as it happens:

```
{"step":"worktree","status":"running"}
{"step":"worktree","status":"done"}
{"step":"hooks","status":"running","message":"pre-create"}
{"step":"hooks","status":"done","message":"pre-create"}
{"step":"env","status":"running"}
...
{"event":"ready","workspace":{ ...record... }}
```

Every stdout line is one JSON object of one of these shapes:

| Line | Meaning |
|---|---|
| `{"step": S, "status": "running"\|"done", "message"?: M}` | Progress. `hooks` is emitted twice, with `message` `pre-create` then `post-create`: key on step + message. A step never carries a `failed` status |
| `{"event": "ready", "workspace": <record>}` | Last line on success |
| `{"event": "failed", "step": S, "message": M}` | Last line on a hard failure, followed by a non-zero exit. Once the worktree exists, `message` names the `ws destroy` command that cleans up |

Step order, `laravel-herd` profile: `worktree`, `hooks` (pre-create), `env`, `deps`, `db`, `test_db`, `storage`, `herd`, `vite`, `caches`, `hooks` (post-create). `plain` profile: `worktree`, `hooks` (pre-create), `env`, `deps`, `hooks` (post-create). Provisioning steps that degrade gracefully (missing tool, DB clone fallback) stay `done` and explain themselves on stderr. Errors are never on stdout: a stream that ends without `ready` nor `failed` (tool killed) must be read as a failure from the exit code.

### `ws setup --json`

Same stream without the `worktree` step. The final line is `{"event":"ready","site":...,"branch":...,"path":...}` (no record: the checkout is not necessarily under `.worktrees/`), and a hard failure is the same `failed` event as above.

### `ws finish <branch> --pr|--merge|--abandon --json`

The mode flag replaces the menu and every prompt, with or without `--json`:

- `--message <msg>` commits pending changes first (without it, uncommitted changes are a user error).
- `--title <title>` sets the PR title (default: last commit subject); the body lists the commits.
- `--cleanup` deletes the workspace afterwards (default: kept). `--abandon` always deletes it.

Prints `{"event":"finished","mode":"pr","site":...,"branch":...,"base":...,"pr_url":"https://...","workspace_removed":false}`. `pr_url` is present only when `gh pr create` succeeded: a missing `gh` or a failed PR creation is a warning on stderr, the command still exits `0` and the branch is pushed.

### `ws destroy <branch> --yes --json`

`--yes` is required in JSON mode. Prints `{"event":"destroyed","site":...,"branch":...}`.

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
| `pre-destroy` | Before `ws destroy` or the Claude Code `WorktreeRemove` adapter removes anything. Not fired by `ws finish --abandon` / `--cleanup`, which fire `post-finish` after the removal |
| `post-finish` | After `ws finish` (PR / merge / abandon) |

The following variables are exported to hooks:

| Variable | Value | Available in |
|---|---|---|
| `WS_EVENT` | Hook name (`post-create`, `pre-destroy`, ...) | all |
| `WS_PROJECT` | Main project name | all |
| `WS_BRANCH` | Branch name | all |
| `WS_SITE` | Slug used for the Herd site / worktree dir | all |
| `WS_DIR` | Absolute path to the worktree (already removed when `post-finish` ran a cleanup) | all |
| `WS_ROOT` | Absolute path to the main repo | all |
| `WS_PROFILE` | `laravel-herd` or `plain` | all |
| `WS_URL` | Full URL (`http(s)://…test`), empty for `plain` | `pre-create`, `post-create` |
| `WS_DB` | Workspace database name (if Laravel + DB detected) | `post-create` |
| `WS_TEST_DB` | Workspace test database name (if a test DB was detected) | `post-create` |
| `WS_BASE` | Base branch targeted by `ws finish` | `post-finish` |

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

## Profiles

`ws` provisions a workspace according to a profile:

| Profile | What `ws create` does |
|---|---|
| `laravel-herd` | Everything described above: `.env` patched, dependencies cloned, database cloned, test database isolated, Herd link, Vite port, caches cleared |
| `plain` | Worktree, `.env` copied as is (only when the workspace has none and the main checkout has one), `.claude/settings.local.json` / `CLAUDE.local.md` copied, `"files"` symlinked, `vendor/` and `node_modules/` cloned copy-on-write (or installed) when `composer.json` / `package.json` exist, `.ws/hooks/` hooks. No database, no test database, no storage clone, no Herd, no Vite patch, no cache clear |

The profile is resolved once per command: `--plain` flag (`ws create`, `ws setup`), then the profile the workspace was provisioned with (recorded in `git config branch.<name>.ws-profile`, next to its base branch), then `"profile"` in `.ws.json`, then detection (`artisan` present → `laravel-herd`, otherwise `plain`). An unknown value is reported and replaced by detection. Hooks receive it as `WS_PROFILE`. `ws status`, `ws finish` and `ws destroy` read the recorded profile, so a workspace created with `--plain` stays plain for its whole life: it is torn down without touching any database or Herd site, and its JSON record carries `"profile": "plain"` and none of the `url`, `db`, `test_db`, `herd` fields. `--secure` and `--fresh` are ignored, with a warning, for plain workspaces, and `ws preview` refuses them.

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
  },
  "files": ["db-prod.toml", ".mcp.local.json"]
}
```

| Key | Purpose |
|---|---|
| `profile` | `laravel-herd` \| `plain` (default: auto-detected, see Profiles) |
| `agent` | Agent CLI launched by `ws run` / `ws open` (default `claude`). Env override: `WS_AGENT` |
| `terminal` | `tmux` \| `iterm` \| `terminal` \| `ghostty` \| `none` (default: auto). Env override: `WS_TERMINAL` |
| `domain` | Env var holding the project's main host, patched to `<project>-<branch>.test` |
| `subdomains` | Map of `prefix → env_var`. Each entry adds a `herd link` (`admin.<project>-<branch>.test`), patches the env var, is added to `SANCTUM_STATEFUL_DOMAINS`, and switches `SESSION_DOMAIN` to `.<project>-<branch>.test` so cookies span all hosts |
| `files` | Gitignored files (relative to the repo root) symlinked from the main checkout into each workspace, so tooling that reads them by relative path (MCP servers, CLIs) keeps working. Existing files are left untouched; missing sources and paths that are not gitignored are skipped with a warning. Files `ws` provisions itself (`.env`, `.env.testing`, `phpunit.xml`, SQLite files, `storage`, `vendor`, `node_modules`) are refused |

With `--secure`, each subdomain is also passed through `herd secure`. `ws destroy` cleans up every subdomain link as long as `.ws.json` is still present at the repo root.

## Naming

Herd sites use the format `project-branch.test` to avoid conflicts between projects:

| Project | Branch | Herd Site |
|---|---|---|
| `my-app` | `feature/login` | `my-app-feature-login.test` |
| `other-app` | `feature/login` | `other-app-feature-login.test` |

`/`, `_` and `.` all become `-`, so `feature/login`, `feature_login` and `release/1.2` (→ `release-1-2`) yield valid site and database names, and two branches that differ only by those characters name the same workspace: the second `ws create` is refused. Database names use `_` instead (`my_app_feature_login`).

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
| `DB_DATABASE` (testing) | `original_test_db_branch_slug`, written to `.env.testing` and `phpunit.xml` |
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

### Tests deadlock or fail randomly
Two suites are sharing one database. `ws` isolates the test DB per workspace, but only for MySQL/MariaDB/PostgreSQL and only when the name is declared in `phpunit.xml`, `phpunit.xml.dist`, or `.env.testing`. A connection defined directly in `config/database.php` is not detected — run `ws setup` in the worktree and check `Test DB` in the summary.

`phpunit.xml` is tracked by git, so `ws` patches it in the worktree and flags it `--skip-worktree`: the change never shows up in `git status`, diffs, or commits. If an upstream change to `phpunit.xml` later blocks a pull or checkout in that worktree, lift the flag with `git update-index --no-skip-worktree phpunit.xml`.

### Blank page / CORS errors
Check that `vite.config.js` has `host: 'localhost'` and `cors: true`. `ws` patches the workspace copy and marks it `skip-worktree`, like `phpunit.xml`, so the patch never shows in `git status` nor lands in a commit; apply the same change on your base branch once. Kill existing Vite processes: `pkill -f "node.*vite"`.

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

## Changelog

- **3.3.1** — `storage/app` is cloned flat again (3.3.0 nested it under `storage/app/app` and dropped the tracked `.gitignore` files); the clone marker moves to `storage/app/.ws-cloned` so it no longer shows up as untracked.
- **3.3.0** — `.` is slugified like `/` and `_`; `--from origin/<branch>` records its base and sets no upstream; `create pr:N` refreshes a force-pushed PR; `finish --abandon` deletes the branch; `finish` refuses a detached HEAD; `setup` re-runs keep `.env`, `storage/app` and the database name; a separate repository under `.worktrees/` is never removed; MySQL passwords go through `MYSQL_PWD`; database and push failures name their cause; `sed` edits are portable and escape their values; JSON output escapes every control character.
- **3.2.0** — `create`/`setup` close their stream with a `failed` event on any hard failure; existing databases are never cloned over; SQLite keeps `DB_DATABASE` and clones the file; `_` and `-` name the same workspace; Vite and `.env.testing` patches are `skip-worktree`; `destroy` lists uncommitted changes; `herd links` read once per command.
- **3.1.0** — The profile is recorded per workspace (`branch.<name>.ws-profile`) and wins over `.ws.json`; detection needs `artisan` only; unknown profiles and invalid `.ws.json` warn instead of failing; `"files"` entries must be gitignored; `WS_PROFILE` reaches every hook; `pg_dump` is found next to `psql`.
- **3.0.2** — `destroy` refuses `.`, `..` and anything outside `.worktrees/`; stale directories never run git commands against the main repo; only `<main database>_…` databases are dropped; `"files"` refuses the files `ws` provisions itself; Laravel projects without `vite.config.*` provision fully.
- **3.0.0** — Profiles (`laravel-herd` / `plain`), `--json` and non-interactive modes, `"files"` symlinks, stale directory detection.

## License

MIT
