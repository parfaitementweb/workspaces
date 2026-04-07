# ws — Workspace manager for Laravel + Claude Code

Creates isolated workspaces via `git worktree`, with automatic setup of Laravel Herd, database, dependencies, and Claude Code session.

Inspired by [Polyscope](https://getpolyscope.com/) and [laravel-herd-worktree](https://github.com/harris21/laravel-herd-worktree), with no third-party app dependency.

## Installation

Clone the repo and create a symlink:

```bash
git clone git@github.com:parfaitementweb/workspaces.git /path/to/workspaces
sudo ln -s /path/to/workspaces/ws /usr/local/bin/ws
```

Since it's a symlink, a `git pull` in the repo will update the `ws` command everywhere.

> Replace `/path/to/workspaces` with the actual location of the cloned repo on your machine.

## Prerequisites

- **Git** (git worktree)
- **Laravel Herd** installed and in PATH
- **Composer** and **npm**
- **Claude Code** (`claude` in PATH)
- **gh** (optional, for creating PRs from `ws finish`)

## Usage

From the root of a Laravel project:

```bash
cd ~/Sites/my-project
```

### Create a workspace

```bash
ws create feature/auth            # HTTP by default
ws create feature/auth --secure   # HTTPS (herd secure)
```

Everything is handled automatically:
- Creates a git worktree in `.worktrees/my-project-feature-auth/`
- Copies `.env` from the main project
- Updates `APP_URL`, `SESSION_DOMAIN`, `SANCTUM_STATEFUL_DOMAINS`, `SESSION_SECURE_COOKIE`
- Creates an isolated database (`myproject_feature_auth`)
- Runs `composer install` and `npm install`
- Runs migrations and seeders
- Links with Herd → `http(s)://my-project-feature-auth.test`
- Checks Vite config (`host: 'localhost'`, `cors: true`)
- Clears Laravel caches

### Launch Claude Code in a workspace

```bash
ws run feature/auth    # opens Claude Code in the worktree
ws run                 # interactive choice if multiple workspaces
```

From a worktree, `ws run` without arguments launches Claude Code right where you are.

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
```

Deletes the worktree, local branch, database, Herd link, and SSL certificate if applicable. Use `--keep-db` to keep the database.

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
| `SESSION_DOMAIN` | `project-branch.test` |
| `SANCTUM_STATEFUL_DOMAINS` | Domain appended (if Sanctum detected) |
| `SESSION_SECURE_COOKIE` | `true` if --secure, `false` otherwise |

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

## License

MIT
