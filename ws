#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ws — Workspace manager for Laravel + AI coding agents
# Creates isolated worktrees with Herd, DB, and auto dependencies
# ─────────────────────────────────────────────

VERSION="2.1.0"
WORKTREES_DIR=".worktrees"
DEFAULT_AGENT="claude"
MAX_LABEL_LEN=60

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

info()    { echo -e "${BLUE}▸${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" >&2; }
header()  { echo -e "\n${BOLD}$1${NC}"; }

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
    error "No git repository found in the directory tree."
    exit 1
}

# Project name from directory
project_name() {
    basename "$(find_project_root)"
}

# Clean slug for branch name (feature/auth → feature-auth)
slugify() {
    echo "$1" | sed 's/[\/]/-/g' | sed 's/[^a-zA-Z0-9._-]/-/g' | tr '[:upper:]' '[:lower:]'
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
detect_default_branch() {
    local root
    root="$(find_project_root)"
    local branch
    branch=$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [[ -z "$branch" ]]; then
        if git -C "$root" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
            branch="main"
        elif git -C "$root" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
            branch="master"
        else
            branch="main"
        fi
    fi
    echo "$branch"
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
_herd_linked() {
    local name="$1" escaped
    escaped="$(printf '%s' "$name" | sed 's/\./\\./g')"
    command -v herd &>/dev/null || return 1
    herd links 2>/dev/null | grep -qE "(^|[[:space:]|])${escaped}([[:space:]|]|\.test|$)"
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
_ws_config_subdomains() {
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

# Set or replace VAR=value in an .env file
_set_env_var() {
    local file="$1" var="$2" value="$3"
    if grep -q "^${var}=" "$file" 2>/dev/null; then
        sed -i '' "s|^${var}=.*|${var}=${value}|" "$file" 2>/dev/null || true
    else
        echo "${var}=${value}" >> "$file"
    fi
}

_get_env_var() {
    local file="$1" var="$2"
    grep "^${var}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

# Copy-on-write directory copy (APFS clonefile). Falls back to a regular copy.
_cow_copy() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 1
    cp -Rc "$src" "$dst" 2>/dev/null || cp -R "$src" "$dst" 2>/dev/null
}

# Run a project-level hook if present at .ws/hooks/<event>
# Expected env: WS_ROOT, optionally WS_PROJECT, WS_BRANCH, WS_SITE, WS_DIR, WS_URL, WS_DB
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
        WS_ROOT="$root" \
        "$hook" || warn "Hook $event exited with error"
    fi
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
            open -na Ghostty --args --working-directory="$dir" -e $command
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
    local branch_name="" secure="" fresh="" open_after="" agent_flag=""
    local -a agent_args=()

    while (( $# )); do
        case "$1" in
            --secure)  secure="--secure" ;;
            --fresh)   fresh="--fresh" ;;
            --open)    open_after="1" ;;
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

    [[ -n "$branch_name" ]] || { error "Usage: ws create <branch-name|pr:NUMBER> [--secure] [--fresh] [--open] [--agent <cmd>]"; exit 1; }

    local root
    root="$(find_project_root)"

    # PR checkout mode: ws create pr:123 → fetch pull/123/head into pr-123, then use it
    if [[ "$branch_name" =~ ^pr:([0-9]+)$ ]]; then
        local pr_num="${BASH_REMATCH[1]}"
        if ! command -v gh >/dev/null 2>&1; then
            error "gh CLI is required for PR checkout (install: https://cli.github.com)"
            exit 1
        fi
        info "Fetching PR #${pr_num}..."
        local head_ref
        head_ref=$(gh pr view "$pr_num" --json headRefName -q .headRefName 2>/dev/null) \
            || { error "PR #${pr_num} not found"; exit 1; }
        git -C "$root" fetch origin "pull/${pr_num}/head:pr-${pr_num}" 2>/dev/null \
            || { error "Failed to fetch pull/${pr_num}/head"; exit 1; }
        branch_name="pr-${pr_num}"
        success "PR #${pr_num} (${head_ref}) fetched as branch ${branch_name}"
    fi

    local sname wt_path
    sname="$(site_name "$branch_name")"
    wt_path="$(worktree_path "$branch_name")"

    if [[ -d "$wt_path" ]]; then
        error "Workspace '$sname' already exists: $wt_path"
        exit 1
    fi

    header "Creating workspace: $sname"

    if ! grep -qx "$WORKTREES_DIR" "$root/.gitignore" 2>/dev/null; then
        echo "$WORKTREES_DIR" >> "$root/.gitignore"
        success ".worktrees added to .gitignore"
    fi

    info "Creating worktree on branch '$branch_name'..."
    cd "$root"
    git worktree add "$wt_path" -b "$branch_name" 2>/dev/null || \
    git worktree add "$wt_path" "$branch_name"
    success "Worktree created: $wt_path"

    _provision "$root" "$branch_name" "$sname" "$wt_path" "$secure" "$fresh"
    _print_summary "$sname" "$branch_name" "$wt_path"

    if [[ -n "$open_after" ]]; then
        local agent
        agent="$(_resolve_agent "$agent_flag" "$root")"
        _open_terminal "$wt_path" "$sname" "$agent $(_shell_quote ${agent_args[@]+"${agent_args[@]}"})" "$root"
    fi
}

# ── SETUP (provision the current directory as a workspace) ──

cmd_setup() {
    local secure="" fresh="" source_root="" name_override="" standalone=""

    while (( $# )); do
        case "$1" in
            --secure)     secure="--secure" ;;
            --fresh)      fresh="--fresh" ;;
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
        || { error "Not inside a git checkout."; exit 1; }

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

    header "Provisioning workspace: $sname"
    [[ -n "$source_root" ]] && info "Source: $source_root"

    _provision "$source_root" "$branch_name" "$sname" "$wt_path" "$secure" "$fresh"
    _print_summary "$sname" "$branch_name" "$wt_path"
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
    main_wt="$(git -C "$top" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')"
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
    export WS_PROJECT="$(basename "${root:-$wt_path}")"
    export WS_BRANCH="$branch_name"
    export WS_SITE="$sname"
    export WS_DIR="$wt_path"
    export WS_URL="${proto}://${sname}.test"
    export WS_ROOT="$root"

    cd "$wt_path"
    _run_hook "pre-create" "$root"
    _setup_env "$root" "$sname" "$secure"
    _setup_agent_files "$root"
    _setup_composer "$root"
    _setup_npm "$root"
    _setup_database "$branch_name" "$root" "$fresh"
    _setup_storage "$root"
    _setup_herd "$sname" "$secure" "$wt_path" "$root"
    _setup_vite
    _clear_cache
    _run_hook "post-create" "$root"
}

_print_summary() {
    local sname="$1" branch_name="$2" wt_path="$3"
    local proto url
    proto="$(site_protocol "$sname")"
    url="${proto}://${sname}.test"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓${NC} ${BOLD}Workspace ready!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}URL${NC}       ${CYAN}${url}${NC}"
    echo -e "  ${BOLD}Branch${NC}    ${branch_name}"
    echo -e "  ${BOLD}Path${NC}      ${DIM}${wt_path}${NC}"

    if [[ -f "$wt_path/.env" ]]; then
        local ws_db
        ws_db="$(_get_env_var "$wt_path/.env" DB_DATABASE)"
        [[ -n "$ws_db" ]] && echo -e "  ${BOLD}Database${NC}  ${ws_db}"
    fi

    echo ""
    echo -e "  ${DIM}Get started:${NC}          cd ${wt_path}"
    echo -e "  ${DIM}Launch agent here:${NC}    ws run"
    echo -e "  ${DIM}Launch in new tab:${NC}    ws open ${branch_name}"
    echo -e "  ${DIM}Open in browser:${NC}      ws preview"
    echo ""
}

# ── SETUP HELPERS ──

_setup_env() {
    local root="$1"
    local sname="$2"
    local secure="${3:-}"

    local proto="http"
    [[ "$secure" == "--secure" ]] && proto="https"

    if [[ -n "$root" && -f "$root/.env" ]]; then
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
            cp "$root/$f" "$f" && success "$f copied from main project"
        fi
    done
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

    local original_db
    original_db="$(_get_env_var "$source_env" DB_DATABASE)"
    [[ -n "$original_db" ]] || return 0

    local branch_slug workspace_db
    branch_slug="$(slugify "$branch_name")"
    workspace_db="$(_truncate_label "${original_db}_${branch_slug//-/_}" 63)"
    workspace_db="${workspace_db//-/_}"

    _set_env_var .env DB_DATABASE "$workspace_db"
    export WS_DB="$workspace_db"

    local db_connection db_user db_pass db_host db_port
    db_connection="$(_get_env_var .env DB_CONNECTION)"
    db_user="$(_get_env_var .env DB_USERNAME)"
    db_pass="$(_get_env_var .env DB_PASSWORD)"
    db_host="$(_get_env_var .env DB_HOST)"
    db_port="$(_get_env_var .env DB_PORT)"
    db_user="${db_user:-root}"
    db_host="${db_host:-127.0.0.1}"

    local cloned=""

    case "${db_connection:-}" in
        mysql|mariadb)
            if command -v mysql &>/dev/null; then
                local -a my_args=(-u"$db_user" -h"$db_host")
                [[ -n "$db_pass" ]] && my_args+=(-p"$db_pass")
                [[ -n "$db_port" ]] && my_args+=(-P"$db_port")

                if mysql "${my_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$workspace_db\`;" 2>/dev/null; then
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
                    warn "Could not create database — do it manually"
                fi
            fi
            ;;
        pgsql)
            local psql_cmd=""
            if command -v psql &>/dev/null; then
                psql_cmd="psql"
            elif [[ -x "$HOME/Library/Application Support/Herd/bin/psql" ]]; then
                psql_cmd="$HOME/Library/Application Support/Herd/bin/psql"
            fi

            if [[ -n "$psql_cmd" ]]; then
                local -a psql_args=(-q -U "$db_user" -h "$db_host")
                [[ -n "${db_port:-}" ]] && psql_args+=(-p "$db_port")
                local pg_dump_cmd="${psql_cmd%psql}pg_dump"
                command -v "$pg_dump_cmd" &>/dev/null || pg_dump_cmd="pg_dump"

                if [[ -z "$fresh" && "$workspace_db" != "$original_db" ]]; then
                    # TEMPLATE clone is instant but needs no active connections on the source
                    if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                        -c "CREATE DATABASE \"$workspace_db\" TEMPLATE \"$original_db\";" 2>/dev/null; then
                        success "Database '$workspace_db' cloned from '$original_db' (TEMPLATE)"
                        cloned="1"
                    elif PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                        -c "CREATE DATABASE \"$workspace_db\";" 2>/dev/null; then
                        success "Database '$workspace_db' created (PostgreSQL)"
                        if command -v "$pg_dump_cmd" &>/dev/null; then
                            info "Cloning data from '$original_db' (pg_dump)..."
                            if PGPASSWORD="${db_pass:-}" "$pg_dump_cmd" -U "$db_user" -h "$db_host" ${db_port:+-p "$db_port"} "$original_db" 2>/dev/null \
                                | PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -q -d "$workspace_db" >/dev/null 2>&1; then
                                success "Database cloned from '$original_db'"
                                cloned="1"
                            else
                                warn "Database clone failed — starting from an empty database"
                            fi
                        fi
                    else
                        warn "Could not create database — do it manually"
                    fi
                else
                    if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                        -c "CREATE DATABASE \"$workspace_db\";" 2>/dev/null; then
                        success "Database '$workspace_db' created (PostgreSQL)"
                    else
                        warn "Could not create database — do it manually"
                    fi
                fi

                local search_path
                search_path="$(_get_env_var .env DB_SEARCH_PATH)"
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
        sqlite)
            local db_path="database/database.sqlite"
            if [[ ! -f "$db_path" ]]; then
                if [[ -z "$fresh" && -n "$root" && -f "$root/$db_path" ]]; then
                    cp -c "$root/$db_path" "$db_path" 2>/dev/null || cp "$root/$db_path" "$db_path"
                    success "SQLite database cloned from main project"
                    cloned="1"
                else
                    touch "$db_path"
                    success "SQLite file created"
                fi
            fi
            ;;
    esac

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

# Uploads (storage/app) cloned via CoW + public/storage symlink
_setup_storage() {
    local root="$1"
    [[ -f "artisan" ]] || return 0

    if [[ -n "$root" && -d "$root/storage/app" ]]; then
        local tmp="storage/.app.ws-tmp"
        rm -rf "$tmp"
        if _cow_copy "$root/storage/app" "$tmp"; then
            rm -rf storage/app && mv "$tmp" storage/app
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
    vite_config="$(ls vite.config.* 2>/dev/null | head -1)"
    [[ -n "$vite_config" ]] || return 0

    local patched=""
    if ! grep -q "host:" "$vite_config" 2>/dev/null; then
        info "Adding host: 'localhost', cors: true, port: from VITE_PORT to $vite_config..."
        if grep -q "server:" "$vite_config" 2>/dev/null; then
            sed -i '' "/server:/a\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\            port: Number(process.env.VITE_PORT) || 5173," "$vite_config" 2>/dev/null || true
        else
            sed -i '' "/plugins:/i\\
\\        server: {\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\            port: Number(process.env.VITE_PORT) || 5173,\\
\\        }," "$vite_config" 2>/dev/null || true
        fi
        patched="1"
        success "vite.config: host: 'localhost', cors: true, port from VITE_PORT"
    elif ! grep -q "process.env.VITE_PORT" "$vite_config" 2>/dev/null; then
        info "Adding port: Number(process.env.VITE_PORT) || 5173 to $vite_config..."
        sed -i '' "/host: 'localhost'/a\\
\\            port: Number(process.env.VITE_PORT) || 5173," "$vite_config" 2>/dev/null || true
        patched="1"
        success "vite.config: port wired to VITE_PORT"
    fi

    if [[ -n "$patched" ]]; then
        warn "$vite_config was patched in this workspace — commit the same change on your base branch once so future workspaces start clean"
    fi
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
        wt_path="$(worktree_path "$arg")"
        if [[ ! -d "$wt_path" ]]; then
            error "Workspace '$(site_name "$arg")' not found."
            exit 1
        fi
    elif wt_path="$(detect_current_worktree)"; then
        :
    else
        local root
        root="$(find_project_root)"
        local wt_dir="$root/$WORKTREES_DIR"

        if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
            error "No workspace found. Use: ws create <branch-name>"
            exit 1
        fi

        header "Available workspaces:" >&2
        local i=1
        local workspaces=()
        for dir in "$wt_dir"/*/; do
            [[ -d "$dir" ]] || continue
            local name branch
            name="$(basename "$dir")"
            workspaces+=("$name")
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")
            echo -e "  ${CYAN}$i)${NC} $name ${DIM}($branch)${NC}" >&2
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

    if ! command -v "$agent" &>/dev/null; then
        error "Agent '$agent' is not installed or not in PATH."
        exit 1
    fi

    info "Launching $agent in '$(basename "$wt_path")'..."
    echo -e "${DIM}─────────────────────────────────────${NC}"

    cd "$wt_path"
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
    local wt_dir="$root/$WORKTREES_DIR"
    local default_branch
    default_branch="$(detect_default_branch)"

    header "$(project_name) — Workspaces"
    echo ""

    if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
        echo -e "  ${DIM}No workspaces.${NC}"
        echo -e "  ${DIM}Use: ws create <branch-name>${NC}"
        return 0
    fi

    for dir in "$wt_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local name branch commits_ahead db_status herd_status url_display dirty_flag
        name="$(basename "$dir")"

        branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")

        if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
            dirty_flag=" ${YELLOW}●${NC}"
        else
            dirty_flag=""
        fi

        commits_ahead=$(git -C "$dir" rev-list --count "$default_branch..HEAD" 2>/dev/null || echo "?")

        if [[ -f "$dir/.env" && -n "$(_get_env_var "$dir/.env" DB_DATABASE)" ]]; then
            db_status="${GREEN}✓${NC} DB"
        else
            db_status="${DIM}– DB${NC}"
        fi

        local proto="http"
        detect_herd_secure "$name" && proto="https"

        if _herd_linked "$name"; then
            herd_status="${GREEN}✓${NC} Herd"
        else
            herd_status="${DIM}– Herd${NC}"
        fi

        url_display="${proto}://$name.test"

        echo -e "  ${BOLD}$name${NC}  ${DIM}($branch)${NC}${dirty_flag}  ${CYAN}+$commits_ahead${NC}  $db_status  $herd_status  ${DIM}→ $url_display${NC}"

        while IFS=: read -r prefix env_var; do
            [[ -z "$prefix" ]] && continue
            echo -e "  ${DIM}└─ → ${proto}://${prefix}.${name}.test${NC}"
        done < <(_ws_config_subdomains "$root")
    done

    echo ""
}

# ── PREVIEW ──

cmd_preview() {
    local sname wt_path

    if [[ -n "${1:-}" ]]; then
        sname="$(site_name "$1")"
    elif wt_path="$(detect_current_worktree)"; then
        sname="$(basename "$wt_path")"
    else
        error "Usage: ws preview <branch-name> (or run from a worktree)"
        exit 1
    fi

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

    local wt_path sname wt_branch
    wt_path="$(_select_workspace "${1:-}" "Which workspace to finish?")"
    sname="$(basename "$wt_path")"

    wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)

    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        warn "Uncommitted changes in '$sname'."
    fi

    header "Finish workspace '$sname' ($wt_branch)"
    echo ""
    echo -e "  ${CYAN}1)${NC} Create a PR from the worktree ${DIM}(recommended)${NC}"
    echo -e "  ${CYAN}2)${NC} Merge into current branch"
    echo -e "  ${CYAN}3)${NC} Abandon changes"
    echo ""
    read -rp "Choice (1-3): " finish_choice

    export WS_PROJECT="$(basename "$root")"
    export WS_BRANCH="$wt_branch"
    export WS_SITE="$sname"
    export WS_DIR="$wt_path"
    export WS_ROOT="$root"

    case "$finish_choice" in
        1) _finish_pr "$sname" "$wt_path" "$wt_branch" "$root" ;;
        2) _finish_merge "$sname" "$wt_path" "$wt_branch" "$root" ;;
        3) _finish_abandon "$sname" "$wt_path" "$wt_branch" "$root" ;;
        *)
            error "Invalid choice."
            exit 1
            ;;
    esac

    _run_hook "post-finish" "$root"
}

_finish_pr() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    cd "$wt_path"

    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        echo ""
        read -rp "Commit message: " commit_msg
        git add -A
        git commit -m "$commit_msg"
        success "Changes committed"
    fi

    info "Pushing branch '$wt_branch'..."
    git push -u origin "$wt_branch" 2>/dev/null && \
        success "Branch pushed" || \
        { error "Push failed."; exit 1; }

    if command -v gh &>/dev/null; then
        local default_branch
        default_branch="$(detect_default_branch)"

        echo ""
        read -rp "PR title: " pr_title

        echo ""
        echo -e "  ${CYAN}1)${NC} I'll write the description on GitHub"
        echo -e "  ${CYAN}2)${NC} Generate from diff"
        echo -e "  ${CYAN}3)${NC} No description"
        echo ""
        read -rp "Description (1-3): " desc_choice

        local pr_body=""
        case "$desc_choice" in
            2) pr_body=$(git log "$default_branch..$wt_branch" --pretty=format:"- %s" 2>/dev/null) ;;
            3) pr_body="" ;;
        esac

        gh pr create --base "$default_branch" --title "$pr_title" --body "$pr_body" 2>/dev/null && \
            success "PR created!" || \
            warn "PR creation failed — create it manually on GitHub"
    else
        warn "gh CLI not installed — create the PR manually on GitHub"
    fi

    echo ""
    read -rp "Delete the workspace now? (y/N): " cleanup
    if [[ "$cleanup" =~ ^[yY]$ ]]; then
        _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
    else
        info "Workspace kept. Use 'ws destroy' to remove it later."
    fi
}

_finish_merge() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        warn "There are uncommitted changes in '$sname'."
        read -rp "Commit them before merging? (Y/n): " do_commit
        if [[ ! "$do_commit" =~ ^[nN]$ ]]; then
            cd "$wt_path"
            echo ""
            read -rp "Commit message: " commit_msg
            git add -A
            git commit -m "$commit_msg"
            success "Changes committed"
        fi
    fi

    local target_branch default_branch
    target_branch="$(git -C "$root" branch --show-current 2>/dev/null)"
    default_branch="$(detect_default_branch)"
    if [[ "$target_branch" == "$default_branch" ]]; then
        warn "The main checkout is on '$default_branch' — this will merge directly into it."
        read -rp "Continue? (y/N): " confirm_main
        [[ "$confirm_main" =~ ^[yY]$ ]] || exit 0
    fi

    header "Merging '$wt_branch' into '$target_branch'"

    cd "$root"
    git merge "$wt_branch" --no-commit --no-ff && \
        success "Merge successful (not committed — check with git status)" || \
        { error "Conflicts detected — resolve them manually."; exit 1; }

    echo ""
    read -rp "Delete the workspace? (y/N): " cleanup
    if [[ "$cleanup" =~ ^[yY]$ ]]; then
        _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
    fi
}

_finish_abandon() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    echo -e "\n${RED}${BOLD}Abandoning workspace '$sname'${NC}"
    echo -e "  ${DIM}All changes will be lost.${NC}"
    echo ""
    read -rp "Confirm? (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || exit 0

    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
}

# ── CLEANUP (shared) ──

_cleanup_workspace() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4" keep_db="${5:-}"

    local vite_pids
    vite_pids=$(pgrep -f "node.*vite.*${sname}" 2>/dev/null || true)
    if [[ -n "$vite_pids" ]]; then
        echo "$vite_pids" | xargs kill 2>/dev/null || true
        success "Vite processes killed"
    fi

    if command -v herd &>/dev/null; then
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

    if [[ "$keep_db" == "--keep-db" ]]; then
        info "Database kept"
    elif [[ -f "$wt_path/.env" ]]; then
        local ws_db db_connection db_user db_pass db_host db_port
        ws_db="$(_get_env_var "$wt_path/.env" DB_DATABASE)"
        db_connection="$(_get_env_var "$wt_path/.env" DB_CONNECTION)"
        db_user="$(_get_env_var "$wt_path/.env" DB_USERNAME)"
        db_pass="$(_get_env_var "$wt_path/.env" DB_PASSWORD)"
        db_host="$(_get_env_var "$wt_path/.env" DB_HOST)"
        db_port="$(_get_env_var "$wt_path/.env" DB_PORT)"
        db_user="${db_user:-root}"
        db_host="${db_host:-127.0.0.1}"

        # Never drop the main project's database
        local main_db=""
        [[ -f "$root/.env" ]] && main_db="$(_get_env_var "$root/.env" DB_DATABASE)"

        if [[ -n "$ws_db" && "$ws_db" != "$main_db" ]]; then
            case "${db_connection:-}" in
                mysql|mariadb)
                    if command -v mysql &>/dev/null; then
                        if mysql \
                            -u"$db_user" \
                            ${db_pass:+-p"$db_pass"} \
                            -h"$db_host" \
                            ${db_port:+-P"$db_port"} \
                            -e "DROP DATABASE IF EXISTS \`$ws_db\`;" 2>/dev/null; then
                            success "Database '$ws_db' dropped"
                        else
                            warn "Could not drop database '$ws_db'"
                        fi
                    fi
                    ;;
                pgsql)
                    local psql_cmd=""
                    if command -v psql &>/dev/null; then
                        psql_cmd="psql"
                    elif [[ -x "$HOME/Library/Application Support/Herd/bin/psql" ]]; then
                        psql_cmd="$HOME/Library/Application Support/Herd/bin/psql"
                    fi

                    if [[ -n "$psql_cmd" ]]; then
                        local psql_args=(-q -U "$db_user" -h "$db_host")
                        [[ -n "${db_port:-}" ]] && psql_args+=(-p "$db_port")

                        if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                            -c "DROP DATABASE IF EXISTS \"$ws_db\" WITH (FORCE);" 2>/dev/null \
                        || PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                            -c "DROP DATABASE IF EXISTS \"$ws_db\";" 2>/dev/null; then
                            success "Database '$ws_db' dropped"
                        else
                            warn "Could not drop database '$ws_db'"
                        fi
                    fi
                    ;;
            esac
        elif [[ -n "$ws_db" ]]; then
            warn "Workspace uses the main database '$ws_db' — not dropped"
        fi
    fi

    cd "$root"
    if git worktree remove "$wt_path" --force 2>/dev/null; then
        success "Worktree removed"
    else
        rm -rf "$wt_path"
        git worktree prune 2>/dev/null || true
        success "Worktree removed (force)"
    fi

    if [[ -n "$wt_branch" ]]; then
        git branch -d "$wt_branch" 2>/dev/null && \
            success "Branch '$wt_branch' deleted" || \
            warn "Branch '$wt_branch' not deleted (not merged yet?)"
    fi

    echo ""
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

    if [[ -z "$branch_name" ]]; then
        error "Usage: ws destroy <branch-name> [--keep-db] [--yes]"
        exit 1
    fi

    local root sname wt_path
    root="$(find_project_root)"
    sname="$(site_name "$branch_name")"
    wt_path="$(worktree_path "$branch_name")"

    if [[ ! -d "$wt_path" ]]; then
        error "Workspace '$sname' not found."
        exit 1
    fi

    local wt_branch
    wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)

    echo -e "${RED}${BOLD}Deleting workspace '$sname'${NC}"
    echo -e "  Worktree: $wt_path"
    echo -e "  Branch:   $wt_branch"
    [[ -n "$keep_db" ]] && echo -e "  ${DIM}(database kept)${NC}"
    echo ""
    if [[ -z "$yes" ]]; then
        read -rp "Confirm? (y/N): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || exit 0
    fi

    export WS_PROJECT="$(basename "$root")"
    export WS_BRANCH="$wt_branch"
    export WS_SITE="$sname"
    export WS_DIR="$wt_path"
    export WS_ROOT="$root"
    _run_hook "pre-destroy" "$root"

    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root" "$keep_db"
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
            printf '{"hookSpecificOutput":{"hookEventName":"WorktreeCreate","worktree_path":"%s"}}\n' "$wt_path"
            ;;
        remove)
            local wt_path
            wt_path="$(_json_field "$input" worktree_path)"
            [[ -d "$wt_path" ]] || exit 0
            [[ "$wt_path" == *"/$WORKTREES_DIR/"* ]] || exit 0

            if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
                warn "Workspace has uncommitted changes — kept (use 'ws destroy' to remove it)" >&2
                exit 0
            fi

            local root sname wt_branch
            root="${wt_path%%/$WORKTREES_DIR/*}"
            sname="$(basename "$wt_path")"
            wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
            cd "$root"
            export WS_PROJECT="$(basename "$root")" WS_BRANCH="$wt_branch" WS_SITE="$sname" WS_DIR="$wt_path" WS_ROOT="$root"
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
    echo -e "      --secure                        HTTPS via herd secure"
    echo -e "      --fresh                         Empty DB + migrate + seed (default: clone main DB)"
    echo -e "      --open                          Open the agent in a new terminal tab when ready"
    echo -e "      --agent <cmd> [-- args]         Agent to launch (default: claude)"
    echo -e "  ws setup [--from <repo>] [--name <site>] [--secure] [--fresh] [--standalone]"
    echo -e "                                      Provision the current checkout as a workspace"
    echo -e "  ws run [branch] [--agent <cmd>] [-- args]   Launch the agent in the workspace"
    echo -e "  ws open [branch] [--agent <cmd>] [-- args]  Same, in a new terminal tab/window"
    echo -e "  ws status                           Show all workspaces and their state"
    echo -e "  ws preview [branch]                 Open the site in the browser"
    echo -e "  ws finish [branch]                  Finish work (PR / merge / abandon)"
    echo -e "  ws destroy <branch> [--keep-db] [-y] Delete the workspace and Herd link"
    echo -e "  ws hook <create|remove>             Claude Code WorktreeCreate/WorktreeRemove adapter"
    echo -e "  ws help                             Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${DIM}cd ~/Sites/my-project${NC}"
    echo -e "  ws create feature/auth --open         ${DIM}# workspace + new tab running claude${NC}"
    echo -e "  ws create feature/auth --secure       ${DIM}# HTTPS with herd secure${NC}"
    echo -e "  ws create pr:42                       ${DIM}# check out PR #42 in a worktree${NC}"
    echo -e "  ws run feature/auth -- --resume       ${DIM}# pass args to the agent${NC}"
    echo -e "  ws open feature/auth --agent codex"
    echo -e "  ws status"
    echo -e "  ws finish                             ${DIM}# guided workflow: PR, merge, or abandon${NC}"
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
    echo -e "  ${DIM}{ \"agent\": \"claude\", \"terminal\": \"iterm\",${NC}"
    echo -e "  ${DIM}  \"domain\": \"APP_DOMAIN\", \"subdomains\": { \"admin\": \"FILAMENT_DOMAIN\" } }${NC}"
    echo -e "  terminal: ${DIM}tmux | iterm | terminal | ghostty | none${NC} (auto-detected by default)"
    echo -e "  Env overrides: ${DIM}WS_AGENT, WS_TERMINAL, WS_SOURCE${NC}"
    echo ""
    echo -e "${BOLD}Hooks:${NC}"
    echo -e "  Drop executables in ${CYAN}.ws/hooks/${NC} at the repo root to run on lifecycle events:"
    echo -e "  ${DIM}pre-create, post-create, pre-destroy, post-finish${NC}"
    echo -e "  Env available to hooks: ${DIM}WS_PROJECT, WS_BRANCH, WS_SITE, WS_DIR, WS_URL, WS_DB, WS_ROOT, WS_EVENT${NC}"
    echo ""
}

# ── MAIN ──

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        create)  cmd_create "$@" ;;
        setup)   cmd_setup "$@" ;;
        run)     cmd_run "$@" ;;
        open)    cmd_open "$@" ;;
        status)  cmd_status "$@" ;;
        preview) cmd_preview "$@" ;;
        finish)  cmd_finish "$@" ;;
        merge)   cmd_finish "$@" ;;
        destroy) cmd_destroy "$@" ;;
        hook)    cmd_hook "$@" ;;
        version|-v|--version) echo "ws $VERSION" ;;
        help|-h|--help) cmd_help ;;
        *)
            error "Unknown command: $command"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
