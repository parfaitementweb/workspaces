#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ws — Workspace manager for Laravel + AI coding agents
# Creates isolated worktrees with Herd, DB, and auto dependencies
# ─────────────────────────────────────────────

VERSION="3.3.1"
WORKTREES_DIR=".worktrees"
DEFAULT_AGENT="claude"
MAX_LABEL_LEN=60
WS_JSON="${WS_JSON:-}"
WS_OUT=1

# Herd only exposes its binaries through ~/.zshrc, so non-interactive shells miss them
HERD_BIN="$HOME/Library/Application Support/Herd/bin"
if [[ -x "$HERD_BIN/herd" ]]; then
    case ":$PATH:" in
        *":$HERD_BIN:"*) ;;
        *) export PATH="$HERD_BIN:$PATH" ;;
    esac
fi

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ──

# In JSON mode stdout carries machine output only: human messages go to stderr.
_out() {
    if [[ -n "$WS_JSON" ]]; then echo -e "$1" >&2; else echo -e "$1"; fi
}
info()    { _out "${BLUE}▸${NC} $1"; }
success() { _out "${GREEN}✓${NC} $1"; }
warn()    { _out "${YELLOW}⚠${NC} $1"; }
header()  { _out "\n${BOLD}$1${NC}"; }
error() {
    if [[ -n "$WS_JSON" ]]; then
        printf '{"error":%s}\n' "$(_json_str "$1")" >&2
    else
        echo -e "${RED}✗${NC} $1" >&2
    fi
}
# Exit codes: 0 success, 1 user error, 2 environment error
fail()     { error "$1"; exit 1; }
fail_env() { error "$1"; exit 2; }

# ── JSON ──

_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        local i c
        for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 127; do
            c="$(printf "\\$(printf '%03o' "$i")")"
            s="${s//"$c"/$(printf '\\u%04x' "$i")}"
        done
    fi
    printf '"%s"' "$s"
}

# One NDJSON progress line per step, JSON mode only
CURRENT_STEP=""
emit_step() {
    CURRENT_STEP="$1"
    [[ -n "$WS_JSON" ]] || return 0
    local name="$1" status="$2" message="${3:-}"
    if [[ -n "$message" ]]; then
        printf '{"step":%s,"status":%s,"message":%s}\n' "$(_json_str "$name")" "$(_json_str "$status")" "$(_json_str "$message")" >&"$WS_OUT"
    else
        printf '{"step":%s,"status":%s}\n' "$(_json_str "$name")" "$(_json_str "$status")" >&"$WS_OUT"
    fi
}

# emit_event <name> [extra members]  →  {"event":"<name>",<extra>}
emit_event() {
    [[ -n "$WS_JSON" ]] || return 0
    local name="$1" extra="${2:-}"
    printf '{"event":%s%s}\n' "$(_json_str "$name")" "${extra:+,$extra}" >&"$WS_OUT"
}

# Find the nearest main repository root (a directory containing a .git *directory*).
# From inside a worktree (.git is a file) this walks up to the main repo.
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    fail_env "No git repository found in the directory tree."
}

# Project name from directory
project_name() {
    basename "$(find_project_root)"
}

# Clean slug for branch name (feature/auth → feature-auth)
slugify() {
    echo "$1" | sed 's/[\/_.]/-/g' | sed 's/[^a-zA-Z0-9-]/-/g' | tr '[:upper:]' '[:lower:]'
}

# Short deterministic hash of a string (6 hex chars)
_short_hash() {
    printf '%s' "$1" | cksum | awk '{printf "%06x", $1 % 16777216}'
}

# Keep a label within DNS / database name limits, deterministically
_truncate_label() {
    local name="$1" max="${2:-$MAX_LABEL_LEN}"
    if (( ${#name} <= max )); then
        echo "$name"
    else
        echo "${name:0:$((max - 7))}-$(_short_hash "$name")"
    fi
}

# Full site name: project-branch
site_name() {
    local proj slug
    proj="$(project_name)"
    slug="$(slugify "$1")"
    _truncate_label "${proj}-${slug}"
}

# Accept either a branch name or an existing site name (as shown by `ws status`)
resolve_site_name() {
    local root
    root="$(find_project_root)"
    [[ -n "$1" ]] || fail "Workspace name required."
    case "$1" in
        .|..|*/*) ;;
        *) [[ -d "$root/$WORKTREES_DIR/$1" ]] && { echo "$1"; return 0; } ;;
    esac
    site_name "$1"
}

# True when <dir> is a direct child of <root>/.worktrees (after resolving symlinks)
_is_workspace_dir() {
    local root="$1" dir="$2" parent real
    parent="$(cd "$root/$WORKTREES_DIR" 2>/dev/null && pwd -P)" || return 1
    real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
    [[ "$real" != "$parent" && "$(dirname "$real")" == "$parent" ]]
}

# True when <dir> is its own git repository (a clone dropped under .worktrees, not a worktree of <root>)
_is_foreign_repo() {
    local root="$1" dir="$2" top common
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ "$top" == "$(cd "$dir" && pwd -P)" ]] || return 1
    common="$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    common="$(cd "$dir" && cd "$common" 2>/dev/null && pwd -P)" || return 1
    [[ "$common" != "$(cd "$root/.git" && pwd -P)" ]]
}

# True when <dir> is a git worktree of <root>. A directory whose worktree was pruned
# (or a foreign checkout dropped under .worktrees) makes git answer for another repo.
_is_live_worktree() {
    local root="$1" dir="$2" top common
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ "$top" == "$(cd "$dir" && pwd -P)" ]] || return 1
    common="$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    [[ -n "$common" ]] || return 1
    common="$(cd "$dir" && cd "$common" 2>/dev/null && pwd -P)" || return 1
    [[ "$common" == "$(cd "$root/.git" && pwd -P)" ]]
}

# Worktree path (uses site_name for the directory)
worktree_path() {
    local root sname
    root="$(find_project_root)"
    sname="$(site_name "$1")"
    echo "$root/$WORKTREES_DIR/$sname"
}

# If the current directory is inside a ws worktree, print the worktree top-level dir
detect_current_worktree() {
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    if [[ "$top" == *"/$WORKTREES_DIR/"* ]]; then
        echo "$top"
        return 0
    fi
    return 1
}

# Detect the default branch (main, master, develop...)
DEFAULT_BRANCH_CACHE="" DEFAULT_BRANCH_CACHE_ROOT=""
detect_default_branch() {
    local root
    root="$(find_project_root)"
    if [[ -n "$DEFAULT_BRANCH_CACHE" && "$DEFAULT_BRANCH_CACHE_ROOT" == "$root" ]]; then
        echo "$DEFAULT_BRANCH_CACHE"
        return 0
    fi
    local branch
    branch=$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
    if [[ -z "$branch" ]]; then
        if git -C "$root" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
            branch="main"
        elif git -C "$root" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
            branch="master"
        else
            branch="main"
        fi
    fi
    DEFAULT_BRANCH_CACHE="$branch" DEFAULT_BRANCH_CACHE_ROOT="$root"
    echo "$branch"
}

# Resolve a start point for a new branch: local branch, then origin/<ref>, then any commit-ish
_resolve_start_point() {
    local root="$1" ref="$2"
    if git -C "$root" show-ref --verify --quiet "refs/heads/$ref" 2>/dev/null; then
        echo "$ref"
    elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$ref" 2>/dev/null; then
        echo "origin/$ref"
    elif git -C "$root" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
        echo "$ref"
    else
        return 1
    fi
}

# The base branch of a workspace is stored in git config so `ws finish` can
# target the branch the work actually started from, not whatever is checked out.
_set_ws_base() {
    local root="$1" branch="$2" base="$3"
    git -C "$root" config "branch.${branch}.ws-base" "$base"
}

_get_ws_base() {
    local root="$1" branch="$2"
    local base
    base="$(git -C "$root" config --get "branch.${branch}.ws-base" 2>/dev/null)"
    [[ -n "$base" ]] && echo "$base" || detect_default_branch
}

# Detect if the Herd site uses HTTPS (checks Herd certificates)
detect_herd_secure() {
    local sname="$1"
    [[ -f "$HOME/.config/herd/ssl/${sname}.test.crt" ]]
}

# Return the protocol to use for the site
site_protocol() {
    if detect_herd_secure "$1"; then echo "https"; else echo "http"; fi
}

# Exact-match check against `herd links` output (avoids feat-auth matching feat-auth-2)
# `herd links` spawns a PHP process: read it once per invocation, drop the cache after link/unlink
HERD_LINKS_CACHE="" HERD_LINKS_LOADED=""
_herd_links() {
    if [[ -z "$HERD_LINKS_LOADED" ]]; then
        HERD_LINKS_CACHE="$(herd links 2>/dev/null || true)"
        HERD_LINKS_LOADED="1"
    fi
    printf '%s\n' "$HERD_LINKS_CACHE"
}
_herd_links_reset() { HERD_LINKS_LOADED=""; }

_herd_linked() {
    local name="$1" escaped
    escaped="$(printf '%s' "$name" | sed 's/\./\\./g')"
    command -v herd &>/dev/null || return 1
    grep -qE "(^|[[:space:]|])${escaped}([[:space:]|]|\.test|$)" <<<"$(_herd_links)"
}

# Deterministic Vite port per workspace (5173..6172) based on site slug
_hash_port() {
    local hash
    hash=$(printf '%s' "$1" | cksum | awk '{print $1}')
    echo $((5173 + hash % 1000))
}

# ── .ws.json config ──

# Read a top-level string value from <root>/.ws.json. Empty if absent.
_ws_config_get() {
    local root="$1" key="$2"
    local config="$root/.ws.json"
    [[ -n "$root" && -f "$config" ]] || return 0
    if command -v jq &>/dev/null; then
        jq -r --arg k "$key" '.[$k] // empty | select(type == "string")' "$config" 2>/dev/null || true
    elif command -v python3 &>/dev/null; then
        python3 - "$config" "$key" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    if isinstance(v, str):
        print(v)
except Exception:
    pass
PY
    fi
}

# Read the "domain" env-var name from .ws.json. Empty if absent.
_ws_config_domain_env() {
    _ws_config_get "$1" "domain"
}

# Emit "<prefix>:<ENV_VAR>" lines from .ws.json subdomains map. Empty if absent.
SUBDOMAINS_CACHE="" SUBDOMAINS_CACHE_ROOT=""
_ws_config_subdomains() {
    local root="$1"
    if [[ -n "$SUBDOMAINS_CACHE_ROOT" && "$SUBDOMAINS_CACHE_ROOT" == "$root" ]]; then
        printf '%s' "$SUBDOMAINS_CACHE"
        return 0
    fi
    SUBDOMAINS_CACHE="$(_ws_config_subdomains_read "$root")" SUBDOMAINS_CACHE_ROOT="$root"
    printf '%s' "$SUBDOMAINS_CACHE"
}
_ws_config_subdomains_read() {
    local root="$1"
    local config="$root/.ws.json"
    [[ -n "$root" && -f "$config" ]] || return 0
    if command -v jq &>/dev/null; then
        jq -r '(.subdomains // {}) | to_entries[] | select(.key != "" and .value != "") | "\(.key):\(.value)"' "$config" 2>/dev/null || true
    elif command -v python3 &>/dev/null; then
        python3 - "$config" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for prefix, env_var in (d.get("subdomains") or {}).items():
        if prefix and env_var:
            print(f"{prefix}:{env_var}")
except Exception:
    pass
PY
    fi
}

_ws_config_has_subdomains() {
    [[ -n "$(_ws_config_subdomains "$1")" ]]
}

# Emit one path per line from the .ws.json "files" array. Empty if absent.
_ws_config_files() {
    local root="$1"
    local config="$root/.ws.json"
    [[ -n "$root" && -f "$config" ]] || return 0
    if command -v jq &>/dev/null; then
        jq -r '(.files // []) | .[] | select(type == "string" and . != "")' "$config" 2>/dev/null || true
    elif command -v python3 &>/dev/null; then
        python3 - "$config" <<'PY' 2>/dev/null || true
import json, sys
try:
    for f in (json.load(open(sys.argv[1])).get("files") or []):
        if isinstance(f, str) and f:
            print(f)
except Exception:
    pass
PY
    fi
}

# In-place sed through a temporary file: works with BSD and GNU sed alike
_sed_inplace() {
    local expr="$1" file="$2" tmp
    tmp="$(mktemp "${file}.ws-XXXXXX")" || return 1
    if sed "$expr" "$file" > "$tmp" 2>/dev/null; then
        cat "$tmp" > "$file" && rm -f "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi
}

# The line that names the cause in a captured error output: the first fatal/error line, else the last one
_last_line() {
    local line
    line="$(printf '%s\n' "$1" | grep -m1 -E '^(fatal|error|ERROR|psql|mysql|mysqldump)' || true)"
    [[ -n "$line" ]] || line="$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -1)"
    printf '%s' "$line"
}

# Escape a value for the right-hand side of a sed s||| expression
_sed_escape() {
    printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Set or replace VAR=value in an .env file
_set_env_var() {
    local file="$1" var="$2" value="$3"
    if [[ -L "$file" ]]; then
        warn "$file is a symlink — not modified"
        return 0
    fi
    if grep -q "^${var}=" "$file" 2>/dev/null; then
        _sed_inplace "s|^${var}=.*|${var}=$(_sed_escape "$value")|" "$file" || true
    else
        echo "${var}=${value}" >> "$file"
    fi
}

_get_env_var() {
    local file="$1" var="$2"
    grep "^${var}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

# pg_dump next to the psql binary itself (Herd's bin only links psql)
_pg_dump_cmd() {
    local psql_cmd real
    psql_cmd="$(_psql_cmd)" || return 1
    psql_cmd="$(command -v "$psql_cmd")" || return 1
    real="$(readlink -f "$psql_cmd" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$psql_cmd" 2>/dev/null || echo "$psql_cmd")"
    if [[ -x "$(dirname "$real")/pg_dump" ]]; then
        echo "$(dirname "$real")/pg_dump"
    elif command -v pg_dump &>/dev/null; then
        echo "pg_dump"
    else
        return 1
    fi
}

_psql_cmd() {
    if command -v psql &>/dev/null; then
        echo "psql"
    elif [[ -x "$HOME/Library/Application Support/Herd/bin/psql" ]]; then
        echo "$HOME/Library/Application Support/Herd/bin/psql"
    else
        return 1
    fi
}

_db_create() {
    local conn="$1" name="$2" user="${3:-}" pass="${4:-}" host="${5:-}" port="${6:-}" search_path="${7:-}"
    user="${user:-root}"
    host="${host:-127.0.0.1}"

    case "$conn" in
        mysql|mariadb)
            command -v mysql &>/dev/null || return 1
            MYSQL_PWD="$pass" mysql -u"$user" -h"$host" ${port:+-P"$port"} \
                -e "CREATE DATABASE IF NOT EXISTS \`$name\`;" 2>/dev/null || return 1
            ;;
        pgsql)
            local psql_cmd
            psql_cmd="$(_psql_cmd)" || return 1
            local -a psql_args=(-q -U "$user" -h "$host")
            [[ -n "$port" ]] && psql_args+=(-p "$port")

            PGPASSWORD="$pass" "$psql_cmd" "${psql_args[@]}" -d postgres \
                -c "CREATE DATABASE \"$name\";" 2>/dev/null \
            || PGPASSWORD="$pass" "$psql_cmd" "${psql_args[@]}" -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname='$name';" 2>/dev/null | grep -q 1 \
            || return 1

            if [[ -n "$search_path" && "$search_path" != "public" ]]; then
                PGPASSWORD="$pass" "$psql_cmd" "${psql_args[@]}" -d "$name" \
                    -c "CREATE SCHEMA IF NOT EXISTS \"$search_path\";" 2>/dev/null || return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

_db_drop() {
    local conn="$1" name="$2" user="${3:-}" pass="${4:-}" host="${5:-}" port="${6:-}"
    user="${user:-root}"
    host="${host:-127.0.0.1}"

    case "$conn" in
        mysql|mariadb)
            command -v mysql &>/dev/null || return 1
            MYSQL_PWD="$pass" mysql -u"$user" -h"$host" ${port:+-P"$port"} \
                -e "DROP DATABASE IF EXISTS \`$name\`;" 2>/dev/null || return 1
            ;;
        pgsql)
            local psql_cmd
            psql_cmd="$(_psql_cmd)" || return 1
            local -a psql_args=(-q -U "$user" -h "$host")
            [[ -n "$port" ]] && psql_args+=(-p "$port")

            PGPASSWORD="$pass" "$psql_cmd" "${psql_args[@]}" -d postgres \
                -c "DROP DATABASE IF EXISTS \"$name\" WITH (FORCE);" 2>/dev/null \
            || PGPASSWORD="$pass" "$psql_cmd" "${psql_args[@]}" -d postgres \
                -c "DROP DATABASE IF EXISTS \"$name\";" 2>/dev/null \
            || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# Read a <env name="VAR" value="…"/> entry from a PHPUnit config file
_get_phpunit_env() {
    local file="$1" var="$2"
    sed -n "s|.*<env[[:space:]]\{1,\}name=\"${var}\"[[:space:]]\{1,\}value=\"\([^\"]*\)\".*|\1|p" "$file" 2>/dev/null | head -1 || true
}

_set_phpunit_env() {
    local file="$1" var="$2" value="$3"
    _sed_inplace "s|\(<env[[:space:]]\{1,\}name=\"${var}\"[[:space:]]\{1,\}value=\)\"[^\"]*\"|\1\"$(_sed_escape "$value")\"|" "$file" || true
}

_phpunit_file() {
    local dir="${1:-.}" f
    for f in "$dir/phpunit.xml" "$dir/phpunit.xml.dist"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# Test database name declared by a project (PHPUnit config wins over .env.testing)
_detect_test_db() {
    local dir="${1:-.}" f v
    for f in "$dir/phpunit.xml" "$dir/phpunit.xml.dist"; do
        if [[ -f "$f" ]]; then
            v="$(_get_phpunit_env "$f" DB_DATABASE)"
            if [[ -n "$v" ]]; then
                [[ "$v" != ":memory:" ]] && echo "$v"
                return 0
            fi
        fi
    done
    if [[ -f "$dir/.env.testing" ]]; then
        v="$(_get_env_var "$dir/.env.testing" DB_DATABASE)"
        [[ -n "$v" && "$v" != ":memory:" ]] && echo "$v"
    fi
    return 0
}

# Value used by the test suite: PHPUnit config, then .env.testing, then .env
_test_env_value() {
    local dir="${1:-.}" var="$2" f v
    for f in "$dir/phpunit.xml" "$dir/phpunit.xml.dist"; do
        if [[ -f "$f" ]]; then
            v="$(_get_phpunit_env "$f" "$var")"
            [[ -n "$v" ]] && { echo "$v"; return 0; }
        fi
    done
    for f in "$dir/.env.testing" "$dir/.env"; do
        if [[ -f "$f" ]]; then
            v="$(_get_env_var "$f" "$var")"
            [[ -n "$v" ]] && { echo "$v"; return 0; }
        fi
    done
    return 0
}

# Read DB_* from an .env file into the DB_CONN/DB_NAME/DB_USER/DB_PASS/DB_HOST/DB_PORT/DB_SEARCH_PATH globals
_read_db_env() {
    local file="$1"
    DB_CONN="$(_get_env_var "$file" DB_CONNECTION)"
    DB_NAME="$(_get_env_var "$file" DB_DATABASE)"
    DB_USER="$(_get_env_var "$file" DB_USERNAME)"
    DB_PASS="$(_get_env_var "$file" DB_PASSWORD)"
    DB_HOST="$(_get_env_var "$file" DB_HOST)"
    DB_PORT="$(_get_env_var "$file" DB_PORT)"
    DB_SEARCH_PATH="$(_get_env_var "$file" DB_SEARCH_PATH)"
    DB_USER="${DB_USER:-root}"
    DB_HOST="${DB_HOST:-127.0.0.1}"
}

# Same, from the test configuration of a checkout (phpunit.xml, then .env.testing)
_read_test_db_env() {
    local dir="$1"
    DB_CONN="$(_test_env_value "$dir" DB_CONNECTION)"
    DB_USER="$(_test_env_value "$dir" DB_USERNAME)"
    DB_PASS="$(_test_env_value "$dir" DB_PASSWORD)"
    DB_HOST="$(_test_env_value "$dir" DB_HOST)"
    DB_PORT="$(_test_env_value "$dir" DB_PORT)"
    DB_SEARCH_PATH="$(_test_env_value "$dir" DB_SEARCH_PATH)"
}

# The WS_* variables every hook receives
_export_ws_env() {
    local root="$1" branch="$2" sname="$3" wt_path="$4"
    export WS_PROJECT="$(basename "${root:-$wt_path}")"
    export WS_BRANCH="$branch"
    export WS_SITE="$sname"
    export WS_DIR="$wt_path"
    export WS_ROOT="$root"
}

# Workspace-scoped database name: <base>_<branch slug>
_workspace_db_name() {
    local base_db="$1" branch_name="$2"
    local branch_slug name
    branch_slug="$(slugify "$branch_name")"
    name="$(_truncate_label "${base_db}_${branch_slug//-/_}" 63)"
    echo "${name//-/_}"
}

_workspace_test_db_name() {
    _workspace_db_name "$1" "$2"
}

# Only databases named by ws itself (<main>_<something>) may ever be dropped
_is_workspace_db_name() {
    local name="$1" main_db="$2"
    [[ -n "$name" && -n "$main_db" && "$name" == "${main_db}_"* ]]
}

# Copy-on-write directory copy (APFS clonefile). Falls back to a regular copy.
_cow_copy() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 1
    cp -Rc "$src" "$dst" 2>/dev/null || cp -R "$src" "$dst" 2>/dev/null
}

# Run a project-level hook if present at .ws/hooks/<event>
# Expected env: WS_ROOT, optionally WS_PROJECT, WS_BRANCH, WS_SITE, WS_DIR, WS_URL, WS_DB, WS_TEST_DB
_run_hook() {
    local event="$1"
    local root="$2"
    [[ -n "$root" ]] || return 0
    local hook="$root/.ws/hooks/$event"
    if [[ -x "$hook" ]]; then
        info "Running hook: $event"
        WS_EVENT="$event" \
        WS_PROJECT="${WS_PROJECT:-$(basename "$root")}" \
        WS_BRANCH="${WS_BRANCH:-}" \
        WS_SITE="${WS_SITE:-}" \
        WS_DIR="${WS_DIR:-}" \
        WS_URL="${WS_URL:-}" \
        WS_DB="${WS_DB:-}" \
        WS_TEST_DB="${WS_TEST_DB:-}" \
        WS_PROFILE="${WS_PROFILE:-}" \
        WS_ROOT="$root" \
        "$hook" || warn "Hook $event exited with error"
    fi
}

# ── Profiles ──

PROFILE_LARAVEL="laravel-herd"
PROFILE_PLAIN="plain"

# The profile a workspace was provisioned with, kept next to its base branch
_set_ws_profile() {
    local repo="$1" branch="$2" profile="$3"
    [[ -n "$branch" ]] || return 0
    git -C "$repo" config "branch.${branch}.ws-profile" "$profile" 2>/dev/null || true
}

_get_ws_profile() {
    local repo="$1" branch="$2"
    [[ -n "$branch" ]] || return 0
    git -C "$repo" config --get "branch.${branch}.ws-profile" 2>/dev/null || true
}

_valid_profile() {
    [[ "$1" == "$PROFILE_LARAVEL" || "$1" == "$PROFILE_PLAIN" ]]
}

# Warn once per run when .ws.json exists but cannot be parsed (its keys are otherwise silently ignored).
# Written to stderr explicitly: callers capture resolve_profile with $(...).
WS_CONFIG_CHECKED=""
_ws_config_check() {
    local config="$1/.ws.json"
    [[ -z "$WS_CONFIG_CHECKED" && -f "$config" ]] || return 0
    WS_CONFIG_CHECKED="1"
    if command -v jq &>/dev/null; then
        jq -e . "$config" >/dev/null 2>&1 || warn ".ws.json is not valid JSON — ignored" >&2
    elif command -v python3 &>/dev/null; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$config" 2>/dev/null || warn ".ws.json is not valid JSON — ignored" >&2
    fi
}

# resolve_profile <root> [flag] [branch]: --plain flag, then the profile stored for <branch>,
# then .ws.json "profile", then detection (artisan → laravel-herd, otherwise plain).
# Unknown values fall back to detection with a warning. Exported as WS_PROFILE.
resolve_profile() {
    local root="${1:-}" flag="${2:-}" branch="${3:-}"
    local profile="$flag" source="flag"
    [[ -z "$root" ]] || _ws_config_check "$root"
    if [[ -z "$profile" && -n "$root" ]]; then
        profile="$(_get_ws_profile "$root" "$branch")"; source="branch.${branch}.ws-profile"
    fi
    if [[ -z "$profile" && -n "$root" ]]; then
        profile="$(_ws_config_get "$root" "profile")"; source=".ws.json"
    fi
    if [[ -n "$profile" ]] && ! _valid_profile "$profile"; then
        warn "Unknown profile '$profile' in $source (laravel-herd|plain) — detecting instead" >&2
        profile=""
    fi
    if [[ -z "$profile" ]]; then
        if [[ -n "$root" && -f "$root/artisan" ]]; then
            profile="$PROFILE_LARAVEL"
        else
            profile="$PROFILE_PLAIN"
        fi
    fi
    export WS_PROFILE="$profile"
    echo "$profile"
}

_profile_is_plain() {
    [[ "${1:-${WS_PROFILE:-}}" == "$PROFILE_PLAIN" ]]
}

# ── Workspace record (shared by status, info and JSON events) ──

# Fill the WR_* globals for <root>/.worktrees/<site>.
# Laravel and Herd fields stay empty when they do not apply.
_workspace_record() {
    local root="$1" sname="$2"
    local dir="$root/$WORKTREES_DIR/$sname"
    WR_SITE="$sname"
    WR_PATH="$dir"
    WR_STALE=""
    _is_live_worktree "$root" "$dir" || WR_STALE="true"
    WR_BRANCH=""
    [[ -n "$WR_STALE" ]] || WR_BRANCH="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
    [[ -z "$WR_STALE" ]] || WR_BRANCH="?"
    [[ -n "$WR_BRANCH" ]] || WR_BRANCH="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "?")"
    WR_BASE="$(_get_ws_base "$root" "$WR_BRANCH")"
    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
        WR_DIRTY="true"
    else
        WR_DIRTY="false"
    fi
    local base_ref
    base_ref="$(_resolve_start_point "$root" "$WR_BASE" 2>/dev/null || echo "$WR_BASE")"
    WR_AHEAD="$(git -C "$dir" rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 0)"
    [[ "$WR_AHEAD" =~ ^[0-9]+$ ]] || WR_AHEAD=0
    WR_URL="" WR_DB="" WR_TEST_DB="" WR_HERD=""
    WR_PROFILE="$(resolve_profile "$root" "" "$WR_BRANCH")"
    _profile_is_plain "$WR_PROFILE" && return 0
    if [[ -f "$dir/.env" ]]; then
        WR_URL="$(_get_env_var "$dir/.env" APP_URL)"
        WR_DB="$(_get_env_var "$dir/.env" DB_DATABASE)"
    fi
    WR_TEST_DB="$(_detect_test_db "$dir")"
    if command -v herd &>/dev/null; then
        if _herd_linked "$sname"; then WR_HERD="true"; else WR_HERD="false"; fi
        [[ -n "$WR_URL" || "$WR_HERD" != "true" ]] || WR_URL="$(site_protocol "$sname")://${sname}.test"
    fi
}

_workspace_json() {
    local json
    json="{\"site\":$(_json_str "$WR_SITE"),\"branch\":$(_json_str "$WR_BRANCH"),\"path\":$(_json_str "$WR_PATH")"
    json+=",\"base\":$(_json_str "$WR_BASE"),\"dirty\":$WR_DIRTY,\"ahead\":$WR_AHEAD,\"profile\":$(_json_str "$WR_PROFILE")"
    [[ -z "$WR_URL" ]]     || json+=",\"url\":$(_json_str "$WR_URL")"
    [[ -z "$WR_DB" ]]      || json+=",\"db\":$(_json_str "$WR_DB")"
    [[ -z "$WR_TEST_DB" ]] || json+=",\"test_db\":$(_json_str "$WR_TEST_DB")"
    [[ -z "$WR_HERD" ]]    || json+=",\"herd\":$WR_HERD"
    [[ -z "$WR_STALE" ]]   || json+=",\"stale\":true"
    printf '%s}' "$json"
}

# ── Agent / terminal ──

# Resolve the agent command: --agent flag > WS_AGENT env > .ws.json "agent" > claude
_resolve_agent() {
    local flag="${1:-}" root="${2:-}"
    local agent="$flag"
    [[ -z "$agent" ]] && agent="${WS_AGENT:-}"
    [[ -z "$agent" && -n "$root" ]] && agent="$(_ws_config_get "$root" "agent")"
    [[ -z "$agent" ]] && agent="$DEFAULT_AGENT"
    echo "$agent"
}

# Shell-quote arguments for embedding in a command string
_shell_quote() {
    local out="" arg
    for arg in "$@"; do
        out+=" $(printf '%q' "$arg")"
    done
    echo "${out# }"
}

# Open a new terminal tab/window running <command> in <dir>.
# Backend: WS_TERMINAL env > .ws.json "terminal" > auto (tmux, iTerm2, Terminal.app, Ghostty)
_open_terminal() {
    local dir="$1" title="$2" command="$3" root="${4:-}"
    local backend="${WS_TERMINAL:-}"
    [[ -z "$backend" && -n "$root" ]] && backend="$(_ws_config_get "$root" "terminal")"

    if [[ -z "$backend" ]]; then
        if [[ -n "${TMUX:-}" ]]; then
            backend="tmux"
        else
            case "${TERM_PROGRAM:-}" in
                iTerm.app)      backend="iterm" ;;
                Apple_Terminal) backend="terminal" ;;
                ghostty)        backend="ghostty" ;;
                *)
                    if [[ -d "/Applications/iTerm.app" ]]; then backend="iterm"
                    elif [[ -d "/Applications/Ghostty.app" ]]; then backend="ghostty"
                    else backend="terminal"; fi
                    ;;
            esac
        fi
    fi

    local shell_cmd
    shell_cmd="cd $(printf '%q' "$dir") && exec $command"

    if [[ "$backend" == "tmux" ]] && ! command -v tmux &>/dev/null; then
        warn "tmux not found — falling back to Terminal.app"
        backend="terminal"
    fi

    case "$backend" in
        tmux)
            tmux new-window -c "$dir" -n "$title" "$command" 2>/dev/null \
                || tmux new-session -d -s "$title" -c "$dir" "$command"
            success "Opened tmux window '$title'"
            return 0
            ;;
        iterm)
            local escaped="${shell_cmd//\\/\\\\}"
            escaped="${escaped//\"/\\\"}"
            osascript >/dev/null <<EOF
tell application "iTerm2"
    activate
    if (count of windows) = 0 then
        set w to (create window with default profile)
    else
        tell current window to create tab with default profile
        set w to current window
    end if
    tell current session of w to write text "$escaped"
end tell
EOF
            success "Opened iTerm2 tab '$title'"
            return 0
            ;;
        ghostty)
            open -na Ghostty --args --working-directory="$dir" -e "${SHELL:-/bin/zsh}" -lc "$shell_cmd"
            success "Opened Ghostty window '$title'"
            return 0
            ;;
        terminal)
            local escaped="${shell_cmd//\\/\\\\}"
            escaped="${escaped//\"/\\\"}"
            osascript >/dev/null <<EOF
tell application "Terminal"
    activate
    do script "$escaped"
end tell
EOF
            success "Opened Terminal window '$title'"
            return 0
            ;;
        none)
            info "Run manually: $shell_cmd"
            return 0
            ;;
        *)
            warn "Unknown terminal backend '$backend' (tmux|iterm|terminal|ghostty|none)"
            info "Run manually: $shell_cmd"
            return 1
            ;;
    esac
}

# ── CREATE ──

cmd_create() {
    local branch_name="" secure="" fresh="" open_after="" agent_flag="" from_flag="" profile_flag=""
    local -a agent_args=()

    while (( $# )); do
        case "$1" in
            --secure)  secure="--secure" ;;
            --fresh)   fresh="--fresh" ;;
            --plain)   profile_flag="$PROFILE_PLAIN" ;;
            --open)    open_after="1" ;;
            --from)    from_flag="${2:-}"; shift ;;
            --from=*)  from_flag="${1#--from=}" ;;
            --agent)   agent_flag="${2:-}"; shift ;;
            --agent=*) agent_flag="${1#--agent=}" ;;
            --)        shift; agent_args=("$@"); break ;;
            -*)        error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$branch_name" ]]; then branch_name="$1"
                else error "Unexpected argument: $1"; exit 1; fi
                ;;
        esac
        shift
    done

    [[ -n "$branch_name" ]] || fail "Usage: ws create <branch-name|pr:NUMBER> [--from <branch>] [--secure] [--fresh] [--plain] [--open] [--agent <cmd>]"

    local root
    root="$(find_project_root)"
    trap _on_provision_exit EXIT
    resolve_profile "$root" "$profile_flag" >/dev/null
    if _profile_is_plain && [[ -n "$secure$fresh" ]]; then
        warn "--secure and --fresh have no effect with the plain profile"
    fi

    # PR checkout mode: ws create pr:123 → fetch pull/123/head into pr-123, then use it
    if [[ "$branch_name" =~ ^pr:([0-9]+)$ ]]; then
        local pr_num="${BASH_REMATCH[1]}"
        command -v gh >/dev/null 2>&1 \
            || _create_failed worktree "gh CLI is required for PR checkout (install: https://cli.github.com)" 2
        local pr_site
        pr_site="$(site_name "pr-${pr_num}")"
        [[ -d "$root/$WORKTREES_DIR/$pr_site" ]] && _create_failed worktree "Workspace '$pr_site' already exists: $root/$WORKTREES_DIR/$pr_site" 1
        info "Fetching PR #${pr_num}..."
        local head_ref refspec="+pull/${pr_num}/head:pr-${pr_num}"
        head_ref=$(gh pr view "$pr_num" --json headRefName -q .headRefName 2>/dev/null) \
            || _create_failed worktree "PR #${pr_num} not found" 1
        # A branch checked out elsewhere cannot be force-updated
        if git -C "$root" worktree list --porcelain 2>/dev/null | grep -qx "branch refs/heads/pr-${pr_num}"; then
            refspec="pull/${pr_num}/head:pr-${pr_num}"
        fi
        git -C "$root" fetch origin "$refspec" 2>/dev/null \
            || _create_failed worktree "Failed to fetch pull/${pr_num}/head into pr-${pr_num} (checked out elsewhere?)" 2
        branch_name="pr-${pr_num}"
        success "PR #${pr_num} (${head_ref}) fetched as branch ${branch_name}"
    fi

    local sname wt_path
    sname="$(site_name "$branch_name")"
    wt_path="$(worktree_path "$branch_name")"

    [[ -d "$wt_path" ]] && _create_failed worktree "Workspace '$sname' already exists: $wt_path" 1

    header "Creating workspace: $sname"
    emit_step worktree running

    if ! grep -qxE "${WORKTREES_DIR//./\\.}/?" "$root/.gitignore" 2>/dev/null; then
        [[ ! -s "$root/.gitignore" || -z "$(tail -c1 "$root/.gitignore")" ]] || echo >> "$root/.gitignore"
        echo "$WORKTREES_DIR" >> "$root/.gitignore"
        success ".worktrees added to .gitignore"
    fi

    cd "$root" || fail_env "Cannot enter $root"
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        [[ -n "$from_flag" ]] && warn "Branch '$branch_name' already exists — --from '$from_flag' ignored"
        info "Creating worktree on existing branch '$branch_name'..."
        git worktree add "$wt_path" "$branch_name" \
            || _create_failed worktree "Failed to create worktree for branch '$branch_name'" 2
    else
        local start_ref start_point
        start_ref="${from_flag:-$(detect_default_branch)}"
        start_ref="${start_ref#origin/}"
        start_point="$(_resolve_start_point "$root" "$start_ref")" \
            || _create_failed worktree "Start point '$start_ref' not found (neither local branch, origin branch, nor commit)" 1
        info "Creating worktree on branch '$branch_name' from '$start_point'..."
        git worktree add --no-track "$wt_path" -b "$branch_name" "$start_point" \
            || _create_failed worktree "Failed to create worktree for branch '$branch_name' from '$start_point'" 2
        if git -C "$root" show-ref --verify --quiet "refs/heads/$start_ref" 2>/dev/null \
           || git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$start_ref" 2>/dev/null; then
            _set_ws_base "$root" "$branch_name" "$start_ref"
        fi
    fi
    success "Worktree created: $wt_path"
    emit_step worktree done
    WS_CREATED_SITE="$sname"

    _provision "$root" "$branch_name" "$sname" "$wt_path" "$secure" "$fresh"
    WS_DONE="1"
    if [[ -n "$WS_JSON" ]]; then
        _workspace_record "$root" "$sname"
        emit_event ready "\"workspace\":$(_workspace_json)"
    else
        _print_summary "$sname" "$branch_name" "$wt_path"
    fi

    if [[ -n "$open_after" ]]; then
        local agent
        agent="$(_resolve_agent "$agent_flag" "$root")"
        _open_terminal "$wt_path" "$sname" "$agent $(_shell_quote ${agent_args[@]+"${agent_args[@]}"})" "$root"
    fi
}

# <step> <message> <exit-code>: report a hard failure of ws create in both output modes
_create_failed() {
    WS_DONE="1"
    emit_event failed "\"step\":$(_json_str "$1"),\"message\":$(_json_str "$2")"
    error "$2"
    exit "${3:-1}"
}

# Armed by create/setup: an errexit death mid-provisioning still closes the stream with a
# failed event and tells how to clean up. Command substitutions never run this trap.
WS_DONE="" WS_CREATED_SITE=""
_on_provision_exit() {
    local code=$?
    [[ -z "$WS_DONE" && "$code" -ne 0 ]] || exit "$code"
    local step="${CURRENT_STEP:-provision}" hint=""
    [[ -z "$WS_CREATED_SITE" ]] || hint=" — run: ws destroy $WS_CREATED_SITE"
    emit_event failed "\"step\":$(_json_str "$step"),\"message\":$(_json_str "Provisioning stopped during step '$step' (exit $code)$hint")"
    error "Provisioning stopped during step '$step'$hint"
    exit "$code"
}

# ── SETUP (provision the current directory as a workspace) ──

cmd_setup() {
    local secure="" fresh="" source_root="" name_override="" standalone="" profile_flag=""

    while (( $# )); do
        case "$1" in
            --secure)     secure="--secure" ;;
            --fresh)      fresh="--fresh" ;;
            --plain)      profile_flag="$PROFILE_PLAIN" ;;
            --from)       source_root="${2:-}"; shift ;;
            --from=*)     source_root="${1#--from=}" ;;
            --name)       name_override="${2:-}"; shift ;;
            --name=*)     name_override="${1#--name=}" ;;
            --standalone) standalone="1" ;;
            *)            error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done

    local wt_path
    wt_path="$(git rev-parse --show-toplevel 2>/dev/null)" \
        || fail_env "Not inside a git checkout."

    [[ -z "$source_root" ]] && source_root="${WS_SOURCE:-}"
    [[ -z "$source_root" ]] && source_root="$(_resolve_source_root "$wt_path")"

    if [[ -n "$source_root" ]]; then
        source_root="$(cd "$source_root" && pwd)"
        [[ "$source_root" == "$wt_path" ]] && { error "Refusing to provision the main repository itself."; exit 1; }
    elif [[ -n "$standalone" ]]; then
        warn "Standalone mode — using .env.example, no hooks/.ws.json"
    else
        error "No source repository detected for $wt_path"
        echo -e "  Pass ${CYAN}--from <main-repo>${NC} (clone/copy of a project) or ${CYAN}--standalone${NC} to provision without one." >&2
        exit 1
    fi

    local branch_name
    branch_name="$(git -C "$wt_path" branch --show-current 2>/dev/null)"
    [[ -z "$branch_name" ]] && branch_name="$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null)"

    local sname
    if [[ -n "$name_override" ]]; then
        sname="$(_truncate_label "$(slugify "$name_override")")"
    elif [[ -n "$source_root" ]]; then
        sname="$(_truncate_label "$(basename "$source_root")-$(slugify "$branch_name")")"
    else
        sname="$(_truncate_label "$(slugify "$(basename "$wt_path")")")"
    fi

    resolve_profile "${source_root:-$wt_path}" "$profile_flag" "$branch_name" >/dev/null
    if _profile_is_plain && [[ -n "$secure$fresh" ]]; then
        warn "--secure and --fresh have no effect with the plain profile"
    fi
    header "Provisioning workspace: $sname ($WS_PROFILE)"
    [[ -n "$source_root" ]] && info "Source: $source_root"

    trap _on_provision_exit EXIT
    _provision "$source_root" "$branch_name" "$sname" "$wt_path" "$secure" "$fresh"
    WS_DONE="1"
    if [[ -n "$WS_JSON" ]]; then
        emit_event ready "\"site\":$(_json_str "$sname"),\"branch\":$(_json_str "$branch_name"),\"path\":$(_json_str "$wt_path")"
    else
        _print_summary "$sname" "$branch_name" "$wt_path"
    fi
}

# Guess the main repository for an arbitrary checkout:
# 1) nested under <root>/.worktrees → root ; 2) git worktree → main worktree ; 3) nothing
_resolve_source_root() {
    local top="$1"
    if [[ "$top" == *"/$WORKTREES_DIR/"* ]]; then
        echo "${top%%/$WORKTREES_DIR/*}"
        return 0
    fi
    local main_wt
    main_wt="$(git -C "$top" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //' || true)"
    if [[ -n "$main_wt" && "$main_wt" != "$top" ]]; then
        echo "$main_wt"
        return 0
    fi
    return 0
}

# ── PROVISION (shared by create and setup) ──

_provision() {
    local root="$1" branch_name="$2" sname="$3" wt_path="$4" secure="${5:-}" fresh="${6:-}"

    local proto
    proto="$(site_protocol "$sname")"
    [[ "$secure" == "--secure" ]] && proto="https"
    _export_ws_env "$root" "$branch_name" "$sname" "$wt_path"
    export WS_URL=""
    _profile_is_plain || export WS_URL="${proto}://${sname}.test"
    _set_ws_profile "${root:-$wt_path}" "$branch_name" "$WS_PROFILE"

    cd "$wt_path" || fail_env "Cannot enter $wt_path"
    emit_step hooks running "pre-create"
    _run_hook "pre-create" "$root"
    emit_step hooks done "pre-create"
    emit_step env running
    if _profile_is_plain; then
        _setup_env_plain "$root"
    else
        _setup_env "$root" "$sname" "$secure" "$fresh"
    fi
    emit_step env done
    emit_step deps running
    _setup_agent_files "$root"
    _setup_local_files "$root"
    _setup_composer "$root"
    _setup_npm "$root"
    emit_step deps done
    if _profile_is_plain; then
        info "Plain profile: no database, Herd link or Vite patch"
        emit_step hooks running "post-create"
        _run_hook "post-create" "$root"
        emit_step hooks done "post-create"
        return 0
    fi
    emit_step db running
    _setup_database "$branch_name" "$root" "$fresh"
    emit_step db done
    emit_step test_db running
    _setup_test_database "$branch_name" "$root"
    emit_step test_db done
    emit_step storage running
    _setup_storage "$root" "$fresh"
    emit_step storage done
    emit_step herd running
    _setup_herd "$sname" "$secure" "$wt_path" "$root"
    emit_step herd done
    emit_step vite running
    _setup_vite
    emit_step vite done
    emit_step caches running
    _clear_cache
    emit_step caches done
    emit_step hooks running "post-create"
    _run_hook "post-create" "$root"
    emit_step hooks done "post-create"
}

_print_summary() {
    local sname="$1" branch_name="$2" wt_path="$3"
    local proto url
    proto="$(site_protocol "$sname")"
    url="${proto}://${sname}.test"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓${NC} ${BOLD}Workspace ready!${NC} ${DIM}(${WS_PROFILE:-$PROFILE_LARAVEL})${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    _profile_is_plain || echo -e "  ${BOLD}URL${NC}       ${CYAN}${url}${NC}"
    echo -e "  ${BOLD}Branch${NC}    ${branch_name}"
    echo -e "  ${BOLD}Path${NC}      ${DIM}${wt_path}${NC}"

    if ! _profile_is_plain; then
        if [[ -f "$wt_path/.env" ]]; then
            local ws_db
            ws_db="$(_get_env_var "$wt_path/.env" DB_DATABASE)"
            [[ -n "$ws_db" ]] && echo -e "  ${BOLD}Database${NC}  ${ws_db}"
        fi

        local ws_test_db
        ws_test_db="$(_detect_test_db "$wt_path")"
        [[ -n "$ws_test_db" ]] && echo -e "  ${BOLD}Test DB${NC}   ${ws_test_db}"
    fi

    echo ""
    echo -e "  ${DIM}Get started:${NC}          cd ${wt_path}"
    echo -e "  ${DIM}Launch agent here:${NC}    ws run"
    echo -e "  ${DIM}Launch in new tab:${NC}    ws open ${branch_name}"
    _profile_is_plain || echo -e "  ${DIM}Open in browser:${NC}      ws preview"
    echo -e "  ${DIM}When done:${NC}            ws finish ${branch_name}  ${DIM}# PR / merge / abandon, then cleanup${NC}"
    echo ""
}

# ── SETUP HELPERS ──

# Plain profile: bring the local .env along, untouched
_setup_env_plain() {
    local root="$1"
    if [[ -n "$root" && -f "$root/.env" && ! -f ".env" ]]; then
        cp "$root/.env" .env
        success ".env copied from main project"
    fi
}

_setup_env() {
    local root="$1"
    local sname="$2"
    local secure="${3:-}"
    local fresh="${4:-}"

    local proto="http"
    [[ "$secure" == "--secure" ]] && proto="https"

    if [[ -f ".env" && "$fresh" != "--fresh" ]]; then
        info ".env already present — kept"
    elif [[ -n "$root" && -f "$root/.env" ]]; then
        cp "$root/.env" .env
        success ".env copied from main project"
    elif [[ ! -f ".env" && -f ".env.example" ]]; then
        cp .env.example .env
        success ".env created from .env.example"
    fi

    if [[ ! -f ".env" ]]; then
        warn "No .env found"
        return 0
    fi

    _set_env_var .env APP_URL "${proto}://${sname}.test"

    # Cookie domain: leading dot when subdomains are declared so cookies span all hosts
    if _ws_config_has_subdomains "$root"; then
        _set_env_var .env SESSION_DOMAIN ".${sname}.test"
    else
        _set_env_var .env SESSION_DOMAIN "${sname}.test"
    fi

    # SANCTUM_STATEFUL_DOMAINS (if Sanctum is used)
    if grep -q "sanctum" composer.json 2>/dev/null; then
        local domains
        domains="${sname}.test"
        while IFS=: read -r prefix env_var; do
            [[ -z "$prefix" ]] && continue
            domains+=",${prefix}.${sname}.test"
        done < <(_ws_config_subdomains "$root")

        local current_domains
        current_domains="$(_get_env_var .env SANCTUM_STATEFUL_DOMAINS)"
        if [[ -n "$current_domains" ]]; then
            _set_env_var .env SANCTUM_STATEFUL_DOMAINS "${current_domains},${domains}"
        else
            _set_env_var .env SANCTUM_STATEFUL_DOMAINS "${domains}"
        fi
        success "SANCTUM_STATEFUL_DOMAINS updated"
    fi

    if [[ "$proto" == "http" ]]; then
        _set_env_var .env SESSION_SECURE_COOKIE false
    else
        _set_env_var .env SESSION_SECURE_COOKIE true
    fi

    # Generate APP_KEY if Laravel and key is empty
    if [[ -f "artisan" ]]; then
        local current_key
        current_key="$(_get_env_var .env APP_KEY)"
        if [[ -z "$current_key" || "$current_key" == "base64:" ]]; then
            php artisan key:generate --quiet 2>/dev/null && success "APP_KEY generated" || true
        fi
    fi

    # Unique Vite port per workspace (avoids npm run dev collisions)
    local vite_port
    vite_port=$(_hash_port "$sname")
    _set_env_var .env VITE_PORT "$vite_port"
    success "VITE_PORT=${vite_port} (unique per workspace)"

    # Shared-service isolation: Redis / Memcached keys, Horizon, Scout indexes
    local ns="${sname//[-.]/_}"
    if grep -qE "=(redis|memcached)[[:space:]]*$" .env 2>/dev/null; then
        _set_env_var .env CACHE_PREFIX "${ns}_cache_"
        _set_env_var .env REDIS_PREFIX "${ns}_"
        success "CACHE_PREFIX / REDIS_PREFIX namespaced (${ns}_)"
    fi
    if grep -q "laravel/horizon" composer.json 2>/dev/null; then
        _set_env_var .env HORIZON_PREFIX "${ns}_horizon:"
        success "HORIZON_PREFIX=${ns}_horizon:"
    fi
    if grep -q "laravel/scout" composer.json 2>/dev/null; then
        _set_env_var .env SCOUT_PREFIX "${ns}_"
        success "SCOUT_PREFIX=${ns}_"
    fi

    # .ws.json domain mappings (main domain + subdomains)
    local domain_env_var
    domain_env_var="$(_ws_config_domain_env "$root")"
    if [[ -n "$domain_env_var" ]]; then
        _set_env_var .env "$domain_env_var" "${sname}.test"
        success "${domain_env_var}=${sname}.test"
    fi
    while IFS=: read -r prefix env_var; do
        [[ -z "$prefix" || -z "$env_var" ]] && continue
        _set_env_var .env "$env_var" "${prefix}.${sname}.test"
        success "${env_var}=${prefix}.${sname}.test"
    done < <(_ws_config_subdomains "$root")

    success ".env configured (APP_URL=${proto}://${sname}.test)"
}

# Carry over local (gitignored) agent config so permissions/instructions survive in the workspace
_setup_agent_files() {
    local root="$1"
    [[ -n "$root" ]] || return 0
    local f
    for f in .claude/settings.local.json CLAUDE.local.md; do
        if [[ -f "$root/$f" && ! -f "$f" ]]; then
            mkdir -p "$(dirname "$f")"
            cp "$root/$f" "$f" && success "$f copied from main project" || warn "$f could not be copied"
        fi
    done
    return 0
}

# Symlink the gitignored files listed in .ws.json "files" to the main checkout
# (single source of truth for local secrets, nothing left behind on destroy)
_setup_local_files() {
    local root="$1"
    [[ -n "$root" ]] || return 0
    local f target
    while IFS= read -r f; do
        f="${f%/}"
        if [[ "$f" == /* || "$f" == ".." || "$f" == ../* || "$f" == */../* || "$f" == */.. ]]; then
            warn "files: '$f' must be a path relative to the repo root — skipped"
            continue
        fi
        if _is_managed_file "$f"; then
            warn "files: '$f' is provisioned by ws and cannot be linked — skipped"
            continue
        fi
        if [[ ! -e "$root/$f" ]]; then
            warn "files: $f not found in main project — skipped"
            continue
        fi
        local ignored=0
        git -C "$root" check-ignore -q -- "$f" 2>/dev/null || ignored=$?
        if (( ignored == 1 )); then
            warn "files: $f is not gitignored (the link would show as an untracked change) — skipped"
            continue
        fi
        [[ -e "$f" || -L "$f" ]] && continue
        mkdir -p "$(dirname "$f")" 2>/dev/null || { warn "files: could not create $(dirname "$f")"; continue; }
        target="$(_relative_path "$root/$f" "$(cd "$(dirname "$f")" && pwd)")"
        ln -s "$target" "$f" && success "$f linked to main project" || warn "files: could not link $f"
    done < <(_ws_config_files "$root")
    return 0
}

# Files and directories ws writes or clones per workspace: linking them would edit the main project
_is_managed_file() {
    case "$1" in
        .env|.env.testing|phpunit.xml|phpunit.xml.dist|database/*.sqlite|storage|storage/*|public/storage|vendor|vendor/*|node_modules|node_modules/*) return 0 ;;
    esac
    return 1
}

# Path of <target> relative to <from_dir>; absolute when it cannot be computed
_relative_path() {
    local target="$1" from_dir="$2"
    if command -v python3 &>/dev/null; then
        python3 -c 'import os, sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$target" "$from_dir" 2>/dev/null && return 0
    fi
    echo "$target"
}

# Clone <dir> from root via CoW when missing locally, then sync if lockfiles differ
_setup_composer() {
    local root="$1"
    [[ -f "composer.json" ]] || return 0

    if [[ ! -d "vendor" && -n "$root" && -d "$root/vendor" ]]; then
        info "Cloning vendor/ from main project (copy-on-write)..."
        if _cow_copy "$root/vendor" vendor; then
            success "vendor/ cloned"
        else
            rm -rf vendor
            warn "vendor/ clone failed — falling back to composer install"
        fi
    fi

    if [[ ! -d "vendor" ]]; then
        info "Installing Composer dependencies..."
        composer install --quiet --no-interaction 2>/dev/null && \
            success "Composer install done" || \
            warn "Composer install failed — do it manually"
    elif [[ -n "$root" && -f "composer.lock" ]] && ! cmp -s composer.lock "$root/composer.lock" 2>/dev/null; then
        info "composer.lock differs from main project — syncing..."
        composer install --quiet --no-interaction 2>/dev/null && \
            success "Composer dependencies synced" || \
            warn "Composer install failed — do it manually"
    fi
}

_setup_npm() {
    local root="$1"
    [[ -f "package.json" ]] || return 0

    if [[ ! -d "node_modules" && -n "$root" && -d "$root/node_modules" ]]; then
        info "Cloning node_modules/ from main project (copy-on-write)..."
        if _cow_copy "$root/node_modules" node_modules; then
            success "node_modules/ cloned"
        else
            rm -rf node_modules
            warn "node_modules/ clone failed — falling back to npm install"
        fi
    fi

    if [[ ! -d "node_modules" ]]; then
        info "Installing NPM dependencies..."
        npm install --silent 2>/dev/null && \
            success "NPM install done" || \
            warn "NPM install failed — do it manually"
    elif [[ -n "$root" && -f "package-lock.json" ]] && ! cmp -s package-lock.json "$root/package-lock.json" 2>/dev/null; then
        info "package-lock.json differs from main project — syncing..."
        npm install --silent 2>/dev/null && \
            success "NPM dependencies synced" || \
            warn "NPM install failed — do it manually"
    fi
}

_setup_database() {
    local branch_name="$1"
    local root="${2:-}"
    local fresh="${3:-}"

    [[ -f ".env" && -f "artisan" ]] || return 0

    # Read DB config from main project .env (before our modifications)
    local source_env="${root:+$root/.env}"
    [[ -z "$source_env" || ! -f "$source_env" ]] && source_env=".env"

    local original_db db_connection cloned=""
    original_db="$(_get_env_var "$source_env" DB_DATABASE)"
    db_connection="$(_get_env_var .env DB_CONNECTION)"
    # Standalone re-runs read the already renamed .env: the original name is kept alongside
    if [[ -z "$root" ]]; then
        local saved_db
        saved_db="$(_get_env_var .env WS_SOURCE_DB)"
        [[ -z "$saved_db" ]] || original_db="$saved_db"
    fi

    if [[ "$db_connection" == "sqlite" ]]; then
        local rc=0
        _setup_sqlite_database "$root" "$fresh" "$original_db" || rc=$?
        case "$rc" in
            0) cloned="1" ;;
            2) return 0 ;;
        esac
        _run_migrations "$cloned"
        return 0
    fi

    [[ -n "$original_db" ]] || return 0

    local workspace_db
    workspace_db="$(_workspace_db_name "$original_db" "$branch_name")"

    _set_env_var .env DB_DATABASE "$workspace_db"
    [[ -n "$root" ]] || _set_env_var .env WS_SOURCE_DB "$original_db"
    export WS_DB="$workspace_db"

    _read_db_env .env
    local db_user="$DB_USER" db_pass="$DB_PASS" db_host="$DB_HOST" db_port="$DB_PORT"

    # An existing database is somebody's data (a re-run, or another workspace): never clone over it
    if _db_exists "$db_connection" "$workspace_db" "$db_user" "$db_pass" "$db_host" "$db_port"; then
        warn "Database '$workspace_db' already exists — kept as is (no clone, no seed)"
        _run_migrations "1"
        return 0
    fi

    case "${db_connection:-}" in
        mysql|mariadb)
            if command -v mysql &>/dev/null; then
                local -a my_args=(-u"$db_user" -h"$db_host")
                [[ -n "$db_port" ]] && my_args+=(-P"$db_port")
                export MYSQL_PWD="$db_pass"

                local db_err=""
                if db_err="$(mysql "${my_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$workspace_db\`;" 2>&1 >/dev/null)"; then
                    success "Database '$workspace_db' created (MySQL)"
                    if [[ -z "$fresh" && "$workspace_db" != "$original_db" ]] && command -v mysqldump &>/dev/null; then
                        info "Cloning data from '$original_db'..."
                        if mysqldump "${my_args[@]}" --single-transaction --routines --triggers "$original_db" 2>/dev/null \
                            | mysql "${my_args[@]}" "$workspace_db" 2>/dev/null; then
                            success "Database cloned from '$original_db'"
                            cloned="1"
                        else
                            warn "Database clone failed — starting from an empty database"
                        fi
                    fi
                else
                    warn "Could not create database — do it manually ($(_last_line "$db_err"))"
                fi
                unset MYSQL_PWD
            fi
            ;;
        pgsql)
            local psql_cmd="" db_err=""
            psql_cmd="$(_psql_cmd)" || psql_cmd=""

            if [[ -n "$psql_cmd" ]]; then
                local -a psql_args=(-q -U "$db_user" -h "$db_host")
                [[ -n "${db_port:-}" ]] && psql_args+=(-p "$db_port")
                local pg_dump_cmd=""
                pg_dump_cmd="$(_pg_dump_cmd)" || pg_dump_cmd=""

                if [[ -z "$fresh" && "$workspace_db" != "$original_db" ]]; then
                    # TEMPLATE clone is instant but needs no active connections on the source
                    if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                        -c "CREATE DATABASE \"$workspace_db\" TEMPLATE \"$original_db\";" 2>/dev/null; then
                        success "Database '$workspace_db' cloned from '$original_db' (TEMPLATE)"
                        cloned="1"
                    elif db_err="$(PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                        -c "CREATE DATABASE \"$workspace_db\";" 2>&1 >/dev/null)"; then
                        success "Database '$workspace_db' created (PostgreSQL)"
                        if [[ -z "$pg_dump_cmd" ]]; then
                            warn "pg_dump not found — database left empty (migrations will run)"
                        else
                            info "Cloning data from '$original_db' (pg_dump)..."
                            if PGPASSWORD="${db_pass:-}" "$pg_dump_cmd" --no-owner --no-privileges -U "$db_user" -h "$db_host" ${db_port:+-p "$db_port"} "$original_db" 2>/dev/null \
                                | PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -q -v ON_ERROR_STOP=1 --single-transaction -d "$workspace_db" >/dev/null 2>&1; then
                                success "Database cloned from '$original_db'"
                                cloned="1"
                            else
                                warn "Database clone failed — starting from an empty database"
                            fi
                        fi
                    else
                        warn "Could not create database — do it manually ($(_last_line "$db_err"))"
                    fi
                else
                    if db_err="$(PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                        -c "CREATE DATABASE \"$workspace_db\";" 2>&1 >/dev/null)"; then
                        success "Database '$workspace_db' created (PostgreSQL)"
                    else
                        warn "Could not create database — do it manually ($(_last_line "$db_err"))"
                    fi
                fi

                local search_path="$DB_SEARCH_PATH"
                if [[ -n "$search_path" && -z "$cloned" ]]; then
                    if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d "$workspace_db" \
                        -c "CREATE SCHEMA IF NOT EXISTS \"$search_path\";" 2>/dev/null; then
                        success "Schema '$search_path' created"
                    else
                        warn "Could not create schema — do it manually"
                    fi
                fi
            else
                warn "psql not found — create PostgreSQL database manually"
            fi
            ;;
    esac

    _run_migrations "$cloned"
}

# <cloned>: seeders only run on a database that did not come from a clone
_run_migrations() {
    local cloned="${1:-}"
    info "Running migrations..."
    if php artisan migrate --force --quiet --no-interaction 2>/dev/null; then
        success "Migrations done"
    else
        warn "Migrations failed — do it manually"
    fi

    if [[ -z "$cloned" && -f "database/seeders/DatabaseSeeder.php" ]]; then
        info "Running seeders..."
        if php artisan db:seed --force --quiet --no-interaction 2>/dev/null; then
            success "Seeders done"
        else
            warn "Seeders failed — do it manually"
        fi
    fi
}

# SQLite keeps DB_DATABASE untouched: the file path is the isolation. Returns 0 when the
# workspace has data (cloned or pre-existing), 1 when the file was created empty, 2 to skip
# migrations altogether (in-memory, or an absolute path shared with the main project).
_setup_sqlite_database() {
    local root="$1" fresh="$2" db_path="${3:-database/database.sqlite}"
    [[ "$db_path" != ":memory:" ]] || return 2
    if [[ "$db_path" == /* ]]; then
        warn "SQLite database is an absolute path ($db_path) shared with the main project — not isolated, left untouched"
        return 2
    fi
    export WS_DB="$db_path"
    [[ ! -f "$db_path" ]] || { info "SQLite database already present — kept"; return 0; }
    mkdir -p "$(dirname "$db_path")" 2>/dev/null || true
    if [[ -z "$fresh" && -n "$root" && -f "$root/$db_path" ]]; then
        if cp -c "$root/$db_path" "$db_path" 2>/dev/null || cp "$root/$db_path" "$db_path" 2>/dev/null; then
            success "SQLite database cloned from main project"
            return 0
        fi
        warn "Could not clone the SQLite database — starting empty"
    fi
    touch "$db_path" 2>/dev/null || { warn "Could not create $db_path"; return 2; }
    success "SQLite file created"
    return 1
}

# True when the database already exists on the server (MySQL/MariaDB/PostgreSQL)
_db_exists() {
    local conn="$1" name="$2" user="${3:-root}" pass="${4:-}" host="${5:-127.0.0.1}" port="${6:-}"
    case "$conn" in
        mysql|mariadb)
            command -v mysql &>/dev/null || return 1
            local out
            out="$(MYSQL_PWD="$pass" mysql -u"$user" -h"$host" ${port:+-P"$port"} -N -e "SHOW DATABASES LIKE '$(printf '%s' "$name" | sed 's/[_%]/\\&/g')';" 2>/dev/null || true)"
            [[ -n "$out" ]]
            ;;
        pgsql)
            local psql_cmd
            psql_cmd="$(_psql_cmd)" || return 1
            local -a psql_args=(-q -U "$user" -h "$host")
            [[ -n "$port" ]] && psql_args+=(-p "$port")
            PGPASSWORD="$pass" "$psql_cmd" "${psql_args[@]}" -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname='$name';" 2>/dev/null | grep -q 1
            ;;
        *) return 1 ;;
    esac
}

_setup_test_database() {
    local branch_name="$1"
    local root="${2:-}"

    [[ -f "artisan" ]] || return 0

    # .env.testing is gitignored, so a fresh worktree never gets one
    if [[ -n "$root" && -f "$root/.env.testing" && ! -f ".env.testing" ]]; then
        cp "$root/.env.testing" .env.testing
        success ".env.testing copied from main project"
    fi

    # Read the name from the main project so re-provisioning stays idempotent
    local test_db=""
    [[ -n "$root" ]] && test_db="$(_detect_test_db "$root")"
    [[ -n "$test_db" ]] || test_db="$(_detect_test_db .)"
    [[ -n "$test_db" ]] || return 0

    local db_connection
    db_connection="$(_test_env_value . DB_CONNECTION)"
    case "${db_connection:-}" in
        mysql|mariadb|pgsql) ;;
        # SQLite test files already live inside the worktree
        *) return 0 ;;
    esac

    local workspace_test_db
    workspace_test_db="$(_workspace_test_db_name "$test_db" "$branch_name")"
    [[ "$workspace_test_db" != "$test_db" ]] || return 0

    _read_test_db_env .
    if _db_create "$db_connection" "$workspace_test_db" "$DB_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT" "$DB_SEARCH_PATH"; then
        success "Test database '$workspace_test_db' created"
    else
        warn "Could not create test database '$workspace_test_db' — do it manually"
    fi

    local phpunit_file
    if phpunit_file="$(_phpunit_file .)"; then
        _set_phpunit_env "$phpunit_file" DB_DATABASE "$workspace_test_db"
        # PHPUnit env entries win over .env.testing, so the tracked file must be
        # patched; skip-worktree keeps that edit out of every diff and commit
        _skip_worktree "$phpunit_file"
        success "$(basename "$phpunit_file") → $workspace_test_db"
    fi

    if [[ -f ".env.testing" ]]; then
        _set_env_var .env.testing DB_DATABASE "$workspace_test_db"
        _skip_worktree .env.testing
    fi

    export WS_TEST_DB="$workspace_test_db"
}

# Uploads (storage/app) cloned via CoW + public/storage symlink
_setup_storage() {
    local root="$1" fresh="${2:-}"
    [[ -f "artisan" ]] || return 0

    local marker="storage/app/.ws-cloned"
    [[ -f "storage/.ws-storage-cloned" && -d "storage/app" ]] && mv "storage/.ws-storage-cloned" "$marker"
    if [[ -f "$marker" && "$fresh" != "--fresh" ]]; then
        info "storage/app already cloned — kept"
    elif [[ -n "$root" && -d "$root/storage/app" ]]; then
        local tmp
        tmp="$(mktemp -d storage/.app.ws-XXXXXX)" || { warn "Could not create a temporary directory in storage/"; return 0; }
        if _cow_copy "$root/storage/app/." "$tmp"; then
            rm -rf storage/app && mv "$tmp" storage/app && touch "$marker"
            success "storage/app cloned from main project"
        else
            rm -rf "$tmp"
        fi
    fi

    if [[ ! -e "public/storage" ]]; then
        php artisan storage:link --quiet 2>/dev/null && success "public/storage linked" || true
    fi
}

_setup_herd() {
    local sname="$1"
    local secure="${2:-}"
    local wt_path="${3:-$PWD}"
    local root="${4:-}"

    if ! command -v herd &>/dev/null; then
        warn "Herd not found in PATH"
        return 0
    fi

    info "Linking with Herd..."
    _herd_links_reset
    (cd "$wt_path" && herd link "$sname") 2>/dev/null && \
        success "Herd link: $sname.test" || \
        { warn "Herd link failed — do it manually"; return 0; }

    if [[ "$secure" == "--secure" ]]; then
        herd secure "$sname" 2>/dev/null && \
            success "Herd secure: https://$sname.test" || \
            warn "Herd secure failed — do it manually"
    fi

    while IFS=: read -r prefix env_var; do
        [[ -z "$prefix" ]] && continue
        (cd "$wt_path" && herd link "${prefix}.${sname}") 2>/dev/null && \
            success "Herd link: ${prefix}.${sname}.test" || \
            warn "Herd link ${prefix}.${sname} failed"
        if [[ "$secure" == "--secure" ]]; then
            herd secure "${prefix}.${sname}" 2>/dev/null && \
                success "Herd secure: https://${prefix}.${sname}.test" || \
                warn "Herd secure ${prefix}.${sname} failed"
        fi
    done < <(_ws_config_subdomains "$root")
}

_setup_vite() {
    local vite_config
    vite_config="$(ls vite.config.* 2>/dev/null | head -1 || true)"
    [[ -n "$vite_config" ]] || return 0

    local patched=""
    if ! grep -q "host:" "$vite_config" 2>/dev/null; then
        info "Adding host: 'localhost', cors: true, port: from VITE_PORT to $vite_config..."
        if grep -q "server:" "$vite_config" 2>/dev/null; then
            _sed_inplace "/server:/a\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\            port: Number(process.env.VITE_PORT) || 5173," "$vite_config" || true
        else
            _sed_inplace "/plugins:/i\\
\\        server: {\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\            port: Number(process.env.VITE_PORT) || 5173,\\
\\        }," "$vite_config" || true
        fi
        patched="1"
        success "vite.config: host: 'localhost', cors: true, port from VITE_PORT"
    elif ! grep -q "process.env.VITE_PORT" "$vite_config" 2>/dev/null; then
        info "Adding port: Number(process.env.VITE_PORT) || 5173 to $vite_config..."
        _sed_inplace "/host: 'localhost'/a\\
\\            port: Number(process.env.VITE_PORT) || 5173," "$vite_config" || true
        patched="1"
        success "vite.config: port wired to VITE_PORT"
    fi

    if [[ -n "$patched" ]]; then
        _skip_worktree "$vite_config"
        warn "$vite_config was patched in this workspace (kept out of diffs and commits) — apply the same change on your base branch once so future workspaces start clean"
    fi
}

# Keep a per-workspace edit of a tracked file out of status, diffs and `git add -A`
_skip_worktree() {
    git ls-files --error-unmatch "$1" &>/dev/null || return 0
    git update-index --skip-worktree "$1" 2>/dev/null || true
}

_clear_cache() {
    [[ -f "artisan" ]] || return 0
    info "Clearing Laravel caches..."
    php artisan config:clear --quiet 2>/dev/null || true
    php artisan cache:clear --quiet 2>/dev/null || true
    php artisan route:clear --quiet 2>/dev/null || true
    php artisan view:clear --quiet 2>/dev/null || true
    success "Laravel caches cleared"
}

# ── Workspace selection (shared by run/open/finish) ──

# Resolve a workspace path from an optional branch arg, the cwd, or an interactive menu
_select_workspace() {
    local arg="${1:-}" prompt="${2:-Choose a workspace}"
    local wt_path

    if [[ -n "$arg" ]]; then
        local root sname
        root="$(find_project_root)"
        sname="$(resolve_site_name "$arg")"
        wt_path="$root/$WORKTREES_DIR/$sname"
        if [[ ! -d "$wt_path" ]]; then
            error "Workspace '$sname' not found."
            exit 1
        fi
    elif wt_path="$(detect_current_worktree)"; then
        :
    else
        local root
        root="$(find_project_root)"
        local wt_dir="$root/$WORKTREES_DIR"

        if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
            fail "No workspace found. Use: ws create <branch-name>"
        fi
        [[ -z "$WS_JSON" ]] || fail "A workspace name is required in --json mode"

        header "Available workspaces:" >&2
        local i=1
        local workspaces=()
        for dir in "$wt_dir"/*/; do
            [[ -d "$dir" ]] || continue
            local name
            name="$(basename "$dir")"
            workspaces+=("$name")
            _workspace_record "$root" "$name"
            echo -e "  ${CYAN}$i)${NC} $name ${DIM}($WR_BRANCH)${NC}" >&2
            ((i++))
        done

        echo "" >&2
        read -rp "$prompt (1-${#workspaces[@]}): " choice
        if [[ "$choice" -ge 1 && "$choice" -le "${#workspaces[@]}" ]] 2>/dev/null; then
            wt_path="$wt_dir/${workspaces[$((choice-1))]}"
        else
            error "Invalid choice."
            exit 1
        fi
    fi

    echo "$wt_path"
}

# Parse "[branch] [--agent X] [-- args...]" into globals for run/open
_parse_agent_args() {
    SEL_BRANCH="" SEL_AGENT=""
    SEL_ARGS=()
    while (( $# )); do
        case "$1" in
            --agent)   SEL_AGENT="${2:-}"; shift ;;
            --agent=*) SEL_AGENT="${1#--agent=}" ;;
            --)        shift; SEL_ARGS=("$@"); break ;;
            -*)        error "Unknown option: $1"; exit 1 ;;
            *)
                if [[ -z "$SEL_BRANCH" ]]; then SEL_BRANCH="$1"
                else error "Unexpected argument: $1"; exit 1; fi
                ;;
        esac
        shift
    done
}

# ── RUN ──

cmd_run() {
    _parse_agent_args "$@"

    local wt_path
    wt_path="$(_select_workspace "$SEL_BRANCH")"

    local root
    root="$(find_project_root)"
    local agent
    agent="$(_resolve_agent "$SEL_AGENT" "$root")"

    command -v "$agent" &>/dev/null || fail_env "Agent '$agent' is not installed or not in PATH."

    info "Launching $agent in '$(basename "$wt_path")'..."
    echo -e "${DIM}─────────────────────────────────────${NC}"

    cd "$wt_path" || fail_env "Cannot enter $wt_path"
    exec "$agent" ${SEL_ARGS[@]+"${SEL_ARGS[@]}"}
}

# ── OPEN (new terminal tab/window with the agent) ──

cmd_open() {
    _parse_agent_args "$@"

    local wt_path
    wt_path="$(_select_workspace "$SEL_BRANCH")"

    local root
    root="$(find_project_root)"
    local agent
    agent="$(_resolve_agent "$SEL_AGENT" "$root")"

    _open_terminal "$wt_path" "$(basename "$wt_path")" "$agent $(_shell_quote ${SEL_ARGS[@]+"${SEL_ARGS[@]}"})" "$root"
}

# ── STATUS ──

cmd_status() {
    local root
    root="$(find_project_root)"
    _ws_config_check "$root"
    local wt_dir="$root/$WORKTREES_DIR"

    local -a sites=()
    local dir
    if [[ -d "$wt_dir" ]]; then
        for dir in "$wt_dir"/*/; do
            [[ -d "$dir" ]] || continue
            sites+=("$(basename "$dir")")
        done
    fi

    local sname
    if [[ -n "$WS_JSON" ]]; then
        local separator=""
        printf '[' >&"$WS_OUT"
        for sname in ${sites[@]+"${sites[@]}"}; do
            _workspace_record "$root" "$sname"
            printf '%s' "$separator" >&"$WS_OUT"
            _workspace_json >&"$WS_OUT"
            separator=","
        done
        printf ']\n' >&"$WS_OUT"
        return 0
    fi

    header "$(project_name) — Workspaces"
    echo ""

    if (( ${#sites[@]} == 0 )); then
        echo -e "  ${DIM}No workspaces.${NC}"
        echo -e "  ${DIM}Use: ws create <branch-name>${NC}"
        return 0
    fi

    for sname in "${sites[@]}"; do
        _workspace_record "$root" "$sname"
        local dirty_flag="" db_status herd_status url_display proto
        [[ "$WR_DIRTY" == "true" ]] && dirty_flag=" ${YELLOW}●${NC}"
        if [[ -n "$WR_DB" ]]; then db_status="${GREEN}✓${NC} DB"; else db_status="${DIM}– DB${NC}"; fi
        if [[ "$WR_HERD" == "true" ]]; then herd_status="${GREEN}✓${NC} Herd"; else herd_status="${DIM}– Herd${NC}"; fi
        proto="$(site_protocol "$sname")"
        url_display="${WR_URL:-${proto}://${sname}.test}"

        if [[ -n "$WR_STALE" ]]; then
            echo -e "  ${DIM}$sname${NC}  ${YELLOW}stale${NC} ${DIM}(no git worktree, run: ws destroy $sname)${NC}"
            continue
        fi
        if _profile_is_plain "$WR_PROFILE"; then
            echo -e "  ${BOLD}$WR_BRANCH${NC}${dirty_flag}  ${CYAN}+$WR_AHEAD${NC}  ${DIM}plain → $WR_PATH${NC}"
            continue
        fi
        echo -e "  ${BOLD}$WR_BRANCH${NC}${dirty_flag}  ${CYAN}+$WR_AHEAD${NC}  $db_status  $herd_status  ${DIM}→ $url_display${NC}"

        while IFS=: read -r prefix env_var; do
            [[ -z "$prefix" ]] && continue
            echo -e "  ${DIM}└─ → ${proto}://${prefix}.${sname}.test${NC}"
        done < <(_ws_config_subdomains "$root")
    done

    echo ""
}

# ── INFO ──

cmd_info() {
    local root sname wt_path
    root="$(find_project_root)"
    _ws_config_check "$root"

    if [[ -n "${1:-}" ]]; then
        sname="$(resolve_site_name "$1")"
    elif wt_path="$(detect_current_worktree)"; then
        sname="$(basename "$wt_path")"
    else
        fail "Usage: ws info <branch-name> (or run from a worktree)"
    fi
    [[ -d "$root/$WORKTREES_DIR/$sname" ]] || fail "Workspace '$sname' not found."

    _workspace_record "$root" "$sname"

    if [[ -n "$WS_JSON" ]]; then
        _workspace_json >&"$WS_OUT"
        printf '\n' >&"$WS_OUT"
        return 0
    fi

    header "$WR_SITE"
    echo ""
    echo -e "  ${BOLD}Branch${NC}    ${WR_BRANCH}  ${DIM}(from ${WR_BASE}, +${WR_AHEAD})${NC}$([[ "$WR_DIRTY" == "true" ]] && echo -e "  ${YELLOW}● uncommitted changes${NC}")"
    echo -e "  ${BOLD}Path${NC}      ${DIM}${WR_PATH}${NC}"
    [[ -n "$WR_URL" ]]     && echo -e "  ${BOLD}URL${NC}       ${CYAN}${WR_URL}${NC}"
    [[ -n "$WR_DB" ]]      && echo -e "  ${BOLD}Database${NC}  ${WR_DB}"
    [[ -n "$WR_TEST_DB" ]] && echo -e "  ${BOLD}Test DB${NC}   ${WR_TEST_DB}"
    [[ -n "$WR_HERD" ]]    && echo -e "  ${BOLD}Herd${NC}      $([[ "$WR_HERD" == "true" ]] && echo -e "${GREEN}linked${NC}" || echo -e "${DIM}not linked${NC}")"
    [[ -n "$WR_STALE" ]]   && echo -e "  ${BOLD}State${NC}     ${YELLOW}stale${NC} ${DIM}(directory without git worktree)${NC}"
    echo ""
}

# ── PREVIEW ──

cmd_preview() {
    local sname wt_path

    if [[ -n "${1:-}" ]]; then
        sname="$(resolve_site_name "$1")"
    elif wt_path="$(detect_current_worktree)"; then
        sname="$(basename "$wt_path")"
    else
        fail "Usage: ws preview <branch-name> (or run from a worktree)"
    fi

    local root
    root="$(find_project_root)"
    _workspace_record "$root" "$sname"
    _profile_is_plain "$WR_PROFILE" && fail "Workspace '$sname' is plain: no Herd site to open."

    local proto
    proto="$(site_protocol "$sname")"
    local url="${proto}://$sname.test"
    info "Opening $url..."
    open "$url"
}

# ── FINISH ──

cmd_finish() {
    local root
    root="$(find_project_root)"

    local branch_arg="" into_flag="" finish_mode=""
    FINISH_AUTO="" FINISH_MESSAGE="" FINISH_TITLE="" FINISH_CLEANUP="" FINISH_PR_URL="" WS_REMOVED=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --into)       into_flag="${2:-}"; shift ;;
            --into=*)     into_flag="${1#--into=}" ;;
            --pr)         finish_mode="pr" ;;
            --merge)      finish_mode="merge" ;;
            --abandon)    finish_mode="abandon" ;;
            --message|-m) FINISH_MESSAGE="${2:-}"; shift ;;
            --message=*)  FINISH_MESSAGE="${1#--message=}" ;;
            --title)      FINISH_TITLE="${2:-}"; shift ;;
            --title=*)    FINISH_TITLE="${1#--title=}" ;;
            --cleanup)    FINISH_CLEANUP="1" ;;
            -*)           fail "Unknown option: $1" ;;
            *)            branch_arg="$1" ;;
        esac
        shift
    done
    [[ -n "$finish_mode" ]] && FINISH_AUTO="1"
    [[ -n "$finish_mode" || -z "$WS_JSON" ]] || fail "ws finish --json requires --pr, --merge or --abandon"

    local wt_path sname wt_branch
    wt_path="$(_select_workspace "$branch_arg" "Which workspace to finish?")"
    sname="$(basename "$wt_path")"
    _is_live_worktree "$root" "$wt_path" || fail "Workspace '$sname' has no git worktree behind it (stale). Run: ws destroy $sname"

    wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
    [[ -n "$wt_branch" ]] || fail "Workspace '$sname' is on a detached HEAD — check out a branch first."
    resolve_profile "$root" "" "$wt_branch" >/dev/null

    local base_branch
    base_branch="${into_flag:-$(_get_ws_base "$root" "$wt_branch")}"
    if ! git -C "$root" show-ref --verify --quiet "refs/heads/$base_branch" 2>/dev/null \
       && ! git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$base_branch" 2>/dev/null; then
        fail "Base branch '$base_branch' not found."
    fi

    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        warn "Uncommitted changes in '$sname'."
    fi

    header "Finish workspace '$sname' ($wt_branch → $base_branch)"
    if [[ -z "$finish_mode" ]]; then
        echo ""
        echo -e "  ${CYAN}1)${NC} Create a PR against '$base_branch' ${DIM}(recommended)${NC}"
        echo -e "  ${CYAN}2)${NC} Merge locally into '$base_branch'"
        echo -e "  ${CYAN}3)${NC} Abandon changes"
        echo ""
        read -rp "Choice (1-3): " finish_choice
        case "$finish_choice" in
            1) finish_mode="pr" ;;
            2) finish_mode="merge" ;;
            3) finish_mode="abandon" ;;
            *) fail "Invalid choice." ;;
        esac
    fi

    _export_ws_env "$root" "$wt_branch" "$sname" "$wt_path"
    export WS_BASE="$base_branch"

    case "$finish_mode" in
        pr)      _finish_pr "$sname" "$wt_path" "$wt_branch" "$root" "$base_branch" ;;
        merge)   _finish_merge "$sname" "$wt_path" "$wt_branch" "$root" "$base_branch" ;;
        abandon) _finish_abandon "$sname" "$wt_path" "$wt_branch" "$root" ;;
    esac

    _run_hook "post-finish" "$root"

    local removed="false"
    [[ -z "$WS_REMOVED" ]] || removed="true"
    local extra
    extra="\"mode\":$(_json_str "$finish_mode"),\"site\":$(_json_str "$sname"),\"branch\":$(_json_str "$wt_branch"),\"base\":$(_json_str "$base_branch")"
    [[ -z "$FINISH_PR_URL" ]] || extra+=",\"pr_url\":$(_json_str "$FINISH_PR_URL")"
    emit_event finished "${extra},\"workspace_removed\":${removed}"
}

# Commit pending changes, prompting for the message unless running non-interactively
_finish_commit_changes() {
    local sname="$1" wt_path="$2"
    [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]] || return 0
    local commit_msg="$FINISH_MESSAGE"
    if [[ -n "$FINISH_AUTO" ]]; then
        [[ -n "$commit_msg" ]] || fail "Uncommitted changes in '$sname': commit them first or pass --message"
    else
        echo ""
        read -rp "Commit message: " commit_msg
    fi
    git -C "$wt_path" add -A || fail "Could not stage changes in '$sname'"
    git -C "$wt_path" commit -m "$commit_msg" || fail "Commit failed in '$sname' (git hooks or identity?)"
    success "Changes committed"
}

# Delete the workspace after a PR or a merge: --cleanup when non-interactive, otherwise ask
_finish_maybe_cleanup() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"
    local cleanup="$FINISH_CLEANUP"
    if [[ -z "$FINISH_AUTO" ]]; then
        echo ""
        read -rp "Delete the workspace now? (y/N): " cleanup
        [[ "$cleanup" =~ ^[yY]$ ]] && cleanup="1" || cleanup=""
    fi
    if [[ -n "$cleanup" ]]; then
        _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
    else
        info "Workspace kept. Use 'ws destroy' to remove it later."
    fi
}

_finish_pr() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4" base_branch="$5"

    cd "$wt_path" || fail_env "Cannot enter $wt_path"

    _finish_commit_changes "$sname" "$wt_path"

    info "Pushing branch '$wt_branch'..."
    local push_err=""
    if push_err="$(git push -u origin "$wt_branch" 2>&1 >/dev/null)"; then
        success "Branch pushed"
    else
        fail_env "Push failed: $(_last_line "$push_err")"
    fi

    if command -v gh &>/dev/null; then
        local pr_title="$FINISH_TITLE" pr_body="" desc_choice="2"
        if [[ -n "$FINISH_AUTO" ]]; then
            [[ -n "$pr_title" ]] || pr_title="$(git log -1 --pretty=%s 2>/dev/null || echo "$wt_branch")"
        else
            echo ""
            read -rp "PR title: " pr_title

            echo ""
            echo -e "  ${CYAN}1)${NC} I'll write the description on GitHub"
            echo -e "  ${CYAN}2)${NC} Generate from diff"
            echo -e "  ${CYAN}3)${NC} No description"
            echo ""
            read -rp "Description (1-3): " desc_choice
        fi

        case "$desc_choice" in
            2)
                local base_ref
                base_ref="$(_resolve_start_point "$root" "$base_branch" 2>/dev/null || echo "$base_branch")"
                pr_body=$(git log "$base_ref..$wt_branch" --pretty=format:"- %s" 2>/dev/null || true)
                ;;
            *) pr_body="" ;;
        esac

        local pr_url
        if pr_url="$(gh pr create --base "$base_branch" --title "$pr_title" --body "$pr_body" 2>/dev/null)"; then
            FINISH_PR_URL="$(printf '%s' "$pr_url" | grep -Eo 'https?://[^[:space:]]+' | tail -1 || true)"
            success "PR created! ${FINISH_PR_URL}"
        else
            warn "PR creation failed — create it manually on GitHub"
        fi
    else
        warn "gh CLI not installed — create the PR manually on GitHub"
    fi

    _finish_maybe_cleanup "$sname" "$wt_path" "$wt_branch" "$root"
}

_finish_merge() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4" base_branch="$5"

    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        local do_commit="y"
        if [[ -z "$FINISH_AUTO" ]]; then
            warn "There are uncommitted changes in '$sname'."
            read -rp "Commit them before merging? (Y/n): " do_commit
        fi
        [[ "$do_commit" =~ ^[nN]$ ]] || _finish_commit_changes "$sname" "$wt_path"
    fi

    local current_branch default_branch
    current_branch="$(git -C "$root" branch --show-current 2>/dev/null)"
    default_branch="$(detect_default_branch)"
    if [[ "$base_branch" == "$default_branch" && -z "$FINISH_AUTO" ]]; then
        warn "This will merge directly into '$default_branch'."
        read -rp "Continue? (y/N): " confirm_main
        [[ "$confirm_main" =~ ^[yY]$ ]] || exit 0
    fi

    cd "$root" || fail_env "Cannot enter $root"
    if [[ "$current_branch" != "$base_branch" ]]; then
        if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
            fail "The main checkout ('$current_branch') has uncommitted changes — commit or stash them before switching to '$base_branch'."
        fi
        info "Switching main checkout from '$current_branch' to '$base_branch'..."
        git checkout "$base_branch" 2>/dev/null \
            || fail_env "Failed to check out '$base_branch'."
    fi

    header "Merging '$wt_branch' into '$base_branch'"

    git merge "$wt_branch" --no-ff >&2 && \
        success "Merged '$wt_branch' into '$base_branch'" || \
        fail "Conflicts detected — resolve them, then run 'git commit' to conclude the merge."

    _finish_maybe_cleanup "$sname" "$wt_path" "$wt_branch" "$root"
}

_finish_abandon() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    _out "\n${RED}${BOLD}Abandoning workspace '$sname'${NC}"
    _out "  ${DIM}All changes will be lost.${NC}"
    if [[ -z "$FINISH_AUTO" ]]; then
        echo ""
        read -rp "Confirm? (y/N): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || exit 0
    fi

    WS_FORCE_BRANCH_DELETE="1"
    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
}

# ── CLEANUP (shared) ──

_drop_test_database() {
    local wt_path="$1" root="${2:-}"

    local ws_test_db main_test_db=""
    ws_test_db="$(_detect_test_db "$wt_path")"
    [[ -n "$root" ]] && main_test_db="$(_detect_test_db "$root")"
    [[ -n "$ws_test_db" ]] || return 0

    if ! _is_workspace_db_name "$ws_test_db" "$main_test_db"; then
        warn "Test database '$ws_test_db' was not created by ws — not dropped"
        return 0
    fi

    _read_test_db_env "$wt_path"
    case "${DB_CONN:-}" in
        mysql|mariadb|pgsql) ;;
        *) return 0 ;;
    esac

    if _db_drop "$DB_CONN" "$ws_test_db" "$DB_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT"; then
        success "Test database '$ws_test_db' dropped"
    else
        warn "Could not drop test database '$ws_test_db'"
    fi
}

_cleanup_workspace() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4" keep_db="${5:-}"

    local profile
    profile="$(resolve_profile "$root" "" "$wt_branch")"
    if _profile_is_plain "$profile"; then
        keep_db="--keep-db"
    fi

    local vite_pids escaped escaped_dir
    escaped="$(printf '%s' "$sname" | sed 's/\./\\./g')"
    escaped_dir="$(printf '%s' "$WORKTREES_DIR" | sed 's/\./\\./g')"
    vite_pids=$(pgrep -f "/${escaped_dir}/${escaped}/.*vite" 2>/dev/null || true)
    if [[ -n "$vite_pids" ]]; then
        echo "$vite_pids" | xargs kill 2>/dev/null || true
        success "Vite processes killed"
    fi

    if ! _profile_is_plain "$profile" && command -v herd &>/dev/null; then
        _herd_links_reset
        herd unsecure "$sname" 2>/dev/null || true
        herd unlink "$sname" 2>/dev/null && \
            success "Herd unlink: $sname" || true

        while IFS=: read -r prefix env_var; do
            [[ -z "$prefix" ]] && continue
            herd unsecure "${prefix}.${sname}" 2>/dev/null || true
            herd unlink "${prefix}.${sname}" 2>/dev/null && \
                success "Herd unlink: ${prefix}.${sname}" || true
        done < <(_ws_config_subdomains "$root")
    fi

    if _profile_is_plain "$profile"; then
        :
    elif [[ "$keep_db" == "--keep-db" ]]; then
        info "Database kept"
    elif [[ -f "$wt_path/.env" ]]; then
        _read_db_env "$wt_path/.env"
        local ws_db="$DB_NAME" db_connection="$DB_CONN" db_user="$DB_USER" db_pass="$DB_PASS" db_host="$DB_HOST" db_port="$DB_PORT"

        local main_db=""
        [[ -f "$root/.env" ]] && main_db="$(_get_env_var "$root/.env" DB_DATABASE)"

        if _is_workspace_db_name "$ws_db" "$main_db"; then
            case "${db_connection:-}" in
                mysql|mariadb|pgsql)
                    if _db_drop "$db_connection" "$ws_db" "$db_user" "$db_pass" "$db_host" "$db_port"; then
                        success "Database '$ws_db' dropped"
                    else
                        warn "Could not drop database '$ws_db'"
                    fi
                    ;;
            esac
        elif [[ -n "$ws_db" ]]; then
            warn "Database '$ws_db' was not created by ws — not dropped"
        fi
    fi

    if [[ "$keep_db" != "--keep-db" ]]; then
        _drop_test_database "$wt_path" "$root"
    fi

    cd "$root" || fail_env "Cannot enter $root"
    _is_workspace_dir "$root" "$wt_path" || fail_env "Refusing to remove '$wt_path': not a workspace directory"
    _is_foreign_repo "$root" "$wt_path" && fail_env "Refusing to remove '$wt_path': a separate git repository"
    if git worktree remove "$wt_path" --force 2>/dev/null; then
        success "Worktree removed"
    else
        rm -rf "$wt_path"
        git worktree prune 2>/dev/null || true
        success "Worktree removed (force)"
    fi

    if [[ -n "$wt_branch" ]]; then
        if [[ -n "${WS_FORCE_BRANCH_DELETE:-}" ]]; then
            git branch -D "$wt_branch" 2>/dev/null && \
                success "Branch '$wt_branch' deleted" || \
                warn "Branch '$wt_branch' could not be deleted"
        elif git branch -d "$wt_branch" 2>/dev/null; then
            success "Branch '$wt_branch' deleted"
        else
            warn "Branch '$wt_branch' kept: not merged into its base yet (delete it with git branch -D)"
        fi
    fi

    WS_REMOVED="1"
    _out ""
    success "Workspace '$sname' cleaned up."
}

# ── DESTROY ──

cmd_destroy() {
    local branch_name="" keep_db="" yes=""
    for arg in "$@"; do
        case "$arg" in
            --keep-db) keep_db="--keep-db" ;;
            --yes|-y)  yes="1" ;;
            *) branch_name="$arg" ;;
        esac
    done

    [[ -n "$branch_name" ]] || fail "Usage: ws destroy <branch-name> [--keep-db] [--yes]"
    [[ -n "$yes" || -z "$WS_JSON" ]] || fail "ws destroy --json requires --yes"

    local root sname wt_path
    root="$(find_project_root)"
    sname="$(resolve_site_name "$branch_name")"
    wt_path="$root/$WORKTREES_DIR/$sname"

    [[ -d "$wt_path" ]] || fail "Workspace '$sname' not found."
    _is_workspace_dir "$root" "$wt_path" || fail "'$sname' is not a workspace directory."
    _is_foreign_repo "$root" "$wt_path" && fail "'$sname' is a separate git repository, not a workspace of this project — remove it yourself."

    local wt_branch="" stale=""
    if _is_live_worktree "$root" "$wt_path"; then
        wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
    else
        stale="1"
    fi

    _out "${RED}${BOLD}Deleting workspace '$sname'${NC}"
    _out "  Worktree: $wt_path"
    if [[ -n "$stale" ]]; then
        _out "  Branch:   ? ${DIM}(stale: no git worktree behind it)${NC}"
    else
        _out "  Branch:   $wt_branch"
        if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
            _out "  ${YELLOW}Uncommitted changes will be lost${NC}"
        fi
    fi
    [[ -z "$keep_db" ]] || _out "  ${DIM}(database kept)${NC}"
    _out ""
    if [[ -z "$yes" ]]; then
        read -rp "Confirm? (y/N): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || exit 0
    fi

    resolve_profile "$root" "" "$wt_branch" >/dev/null
    _export_ws_env "$root" "$wt_branch" "$sname" "$wt_path"
    _run_hook "pre-destroy" "$root"

    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root" "$keep_db"
    emit_event destroyed "\"site\":$(_json_str "$sname"),\"branch\":$(_json_str "$wt_branch")"
}

# ── HOOK (adapter for Claude Code WorktreeCreate / WorktreeRemove) ──
# settings.json:
#   "hooks": { "WorktreeCreate": [{ "type": "command", "command": "ws hook create" }],
#              "WorktreeRemove": [{ "type": "command", "command": "ws hook remove" }] }

_json_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true
    else
        printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    fi
}

cmd_hook() {
    local event="${1:-}"
    local input
    input="$(cat)"

    case "$event" in
        create)
            local name cwd
            name="$(_json_field "$input" worktree_name)"
            cwd="$(_json_field "$input" cwd)"
            [[ -n "$name" ]] || name="ws-$(_short_hash "$input")"
            [[ -n "$cwd" ]] && cd "$cwd"

            # All human output goes to stderr: stdout is reserved for the JSON reply
            cmd_create "$name" >&2

            local wt_path
            wt_path="$(worktree_path "$name")"
            printf '{"hookSpecificOutput":{"hookEventName":"WorktreeCreate","worktree_path":%s}}\n' "$(_json_str "$wt_path")"
            ;;
        remove)
            local wt_path
            wt_path="$(_json_field "$input" worktree_path)"
            [[ -d "$wt_path" ]] || exit 0
            [[ "$wt_path" == *"/$WORKTREES_DIR/"* ]] || exit 0

            local root sname wt_branch=""
            root="${wt_path%%/$WORKTREES_DIR/*}"
            sname="$(basename "$wt_path")"
            _is_workspace_dir "$root" "$wt_path" || exit 0
            _is_foreign_repo "$root" "$wt_path" && exit 0

            if _is_live_worktree "$root" "$wt_path"; then
                if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
                    warn "Workspace has uncommitted changes — kept (use 'ws destroy' to remove it)" >&2
                    exit 0
                fi
                wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
            fi
            cd "$root" || fail_env "Cannot enter $root"
            resolve_profile "$root" "" "$wt_branch" >/dev/null
            _export_ws_env "$root" "$wt_branch" "$sname" "$wt_path"
            _run_hook "pre-destroy" "$root" >&2
            _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root" >&2
            ;;
        *)
            error "Usage: ws hook <create|remove>  (reads Claude Code hook JSON on stdin)"
            exit 1
            ;;
    esac
}

# ── HELP ──

cmd_help() {
    echo ""
    echo -e "${BOLD}ws${NC} v$VERSION — Workspace manager for Laravel + AI coding agents"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ws create <branch|pr:N> [options]   Create a workspace (branch or GitHub PR)"
    echo -e "      --from <branch>                 Branch to start from (default: repo default branch)"
    echo -e "      --secure                        HTTPS via herd secure"
    echo -e "      --fresh                         Empty DB + migrate + seed (default: clone main DB)"
    echo -e "      --plain                         Worktree + deps only, no DB, Herd or Vite (auto on non-Laravel repos)"
    echo -e "      --open                          Open the agent in a new terminal tab when ready"
    echo -e "      --agent <cmd> [-- args]         Agent to launch (default: claude)"
    echo -e "  ws setup [--from <repo>] [--name <site>] [--secure] [--fresh] [--plain] [--standalone]"
    echo -e "                                      Provision the current checkout as a workspace"
    echo -e "  ws run [branch] [--agent <cmd>] [-- args]   Launch the agent in the workspace"
    echo -e "  ws open [branch] [--agent <cmd>] [-- args]  Same, in a new terminal tab/window"
    echo -e "  ws status                           Show all workspaces and their state"
    echo -e "  ws info [branch]                    Show one workspace"
    echo -e "  ws preview [branch]                 Open the site in the browser"
    echo -e "  ws finish|merge [branch] [--into <branch>]  Finish work (PR / merge / abandon)"
    echo -e "      --into <branch>                 Target branch (default: the branch the workspace was created from)"
    echo -e "      --pr | --merge | --abandon      Skip the menu and every prompt"
    echo -e "      --message|-m <msg> --title <t>  Commit message / PR title when non-interactive"
    echo -e "      --cleanup                       Delete the workspace afterwards when non-interactive"
    echo -e "  ws destroy <branch> [--keep-db] [--yes|-y]  Delete the workspace, databases and Herd link"
    echo -e "  ws hook <create|remove>             Claude Code WorktreeCreate/WorktreeRemove adapter"
    echo -e "  ws help                             Show this help"
    echo ""
    echo -e "${BOLD}Machine output:${NC}"
    echo -e "  Add ${CYAN}--json${NC} to any command: status/info print records, create streams NDJSON steps,"
    echo -e "  finish/destroy print one event and refuse to prompt. Errors are {\"error\":...} on stderr."
    echo -e "  WS_JSON=1 in the environment is equivalent. Exit codes: 0 success, 1 user error, 2 environment error."
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${DIM}cd ~/Sites/my-project${NC}"
    echo -e "  ws create feature/auth --open         ${DIM}# workspace + new tab running claude${NC}"
    echo -e "  ws create feature/auth --secure       ${DIM}# HTTPS with herd secure${NC}"
    echo -e "  ws create feature/auth --from develop ${DIM}# branch off develop instead of main${NC}"
    echo -e "  ws create pr:42                       ${DIM}# check out PR #42 in a worktree${NC}"
    echo -e "  ws run feature/auth -- --resume       ${DIM}# pass args to the agent${NC}"
    echo -e "  ws open feature/auth --agent codex"
    echo -e "  ws status"
    echo -e "  ws finish                             ${DIM}# guided workflow: PR, merge, or abandon${NC}"
    echo -e "  ws finish feature/auth --into develop ${DIM}# target develop instead of the recorded base${NC}"
    echo -e "  ws destroy feature/auth"
    echo ""
    echo -e "${BOLD}Speed:${NC}"
    echo -e "  vendor/, node_modules/ and storage/app are cloned from the main project with"
    echo -e "  APFS copy-on-write; the database is cloned (PG TEMPLATE / mysqldump)."
    echo ""
    echo -e "${BOLD}Naming:${NC}"
    echo -e "  Herd sites use the format ${CYAN}project-branch.test${NC}"
    echo -e "  E.g.: project ${DIM}my-app${NC} + branch ${DIM}feature/login${NC} → ${CYAN}my-app-feature-login.test${NC}"
    echo ""
    echo -e "${BOLD}Config (.ws.json at repo root):${NC}"
    echo -e "  ${DIM}{ \"agent\": \"claude\", \"terminal\": \"iterm\", \"profile\": \"laravel-herd\",${NC}"
    echo -e "  ${DIM}  \"domain\": \"APP_DOMAIN\", \"subdomains\": { \"admin\": \"FILAMENT_DOMAIN\" },${NC}"
    echo -e "  ${DIM}  \"files\": [\"db-prod.toml\"] }${NC}"
    echo -e "  files: ${DIM}gitignored files symlinked from the main checkout into each workspace${NC}"
    echo -e "  terminal: ${DIM}tmux | iterm | terminal | ghostty | none${NC} (auto-detected by default)"
    echo -e "  Env overrides: ${DIM}WS_AGENT, WS_TERMINAL, WS_SOURCE, WS_JSON${NC}"
    echo ""
    echo -e "${BOLD}Hooks:${NC}"
    echo -e "  Drop executables in ${CYAN}.ws/hooks/${NC} at the repo root to run on lifecycle events:"
    echo -e "  ${DIM}pre-create, post-create, pre-destroy, post-finish${NC}"
    echo -e "  Env available to hooks: ${DIM}WS_PROJECT, WS_BRANCH, WS_SITE, WS_DIR, WS_ROOT, WS_EVENT, WS_PROFILE,${NC}"
    echo -e "                          ${DIM}WS_URL, WS_DB, WS_TEST_DB (create hooks), WS_BASE (post-finish)${NC}"
    echo ""
}

# ── MAIN ──

main() {
    # Global --json flag, accepted anywhere before "--" (agent arguments are left untouched)
    local -a args=()
    local arg passthrough=""
    for arg in "$@"; do
        if [[ -z "$passthrough" && "$arg" == "--json" ]]; then
            WS_JSON="1"
        else
            [[ "$arg" == "--" ]] && passthrough="1"
            args+=("$arg")
        fi
    done
    set -- ${args[@]+"${args[@]}"}

    # JSON mode: the real stdout is kept on fd 3 for JSON lines only, everything
    # else (including the tools ws shells out to) goes to stderr.
    if [[ -n "$WS_JSON" ]]; then
        exec 3>&1 1>&2
        WS_OUT=3
    fi

    local command="${1:-help}"
    shift || true

    case "$command" in
        create)  cmd_create "$@" ;;
        setup)   cmd_setup "$@" ;;
        run)     cmd_run "$@" ;;
        open)    cmd_open "$@" ;;
        status)  cmd_status "$@" ;;
        info)    cmd_info "$@" ;;
        preview) cmd_preview "$@" ;;
        finish)  cmd_finish "$@" ;;
        merge)   cmd_finish "$@" ;;
        destroy) cmd_destroy "$@" ;;
        hook)    cmd_hook "$@" ;;
        version|-v|--version) echo "ws $VERSION" ;;
        help|-h|--help) cmd_help ;;
        *)
            error "Unknown command: $command"
            cmd_help >&2
            exit 1
            ;;
    esac
}

main "$@"
