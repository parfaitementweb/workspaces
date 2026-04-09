#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ws — Workspace manager for Laravel + Claude Code
# Creates isolated worktrees with Herd, DB, and auto dependencies
# ─────────────────────────────────────────────

VERSION="2.0.0"
WORKTREES_DIR=".worktrees"

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

# Find the nearest git project root
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

# Full site name: project-branch
site_name() {
    local proj
    proj="$(project_name)"
    local slug
    slug="$(slugify "$1")"
    echo "${proj}-${slug}"
}

# Worktree path (uses site_name for the directory)
worktree_path() {
    local root
    root="$(find_project_root)"
    local sname
    sname="$(site_name "$1")"
    echo "$root/$WORKTREES_DIR/$sname"
}

# Check if we're inside a worktree and return its path
detect_current_worktree() {
    if [[ "$PWD" == *"$WORKTREES_DIR"* ]]; then
        echo "$PWD"
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
        # Fallback: try main, then master
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
    # Herd stores certificates in ~/.config/herd/ssl
    if [[ -f "$HOME/.config/herd/ssl/${sname}.test.crt" ]]; then
        return 0  # HTTPS
    fi
    return 1  # HTTP
}

# Return the protocol to use for the site
site_protocol() {
    local sname="$1"
    if detect_herd_secure "$sname"; then
        echo "https"
    else
        echo "http"
    fi
}

# Deterministic Vite port per workspace (5173..6172) based on site slug
_hash_port() {
    local name="$1"
    local hash
    hash=$(printf '%s' "$name" | cksum | awk '{print $1}')
    echo $((5173 + hash % 1000))
}

# Run a project-level hook if present at .ws/hooks/<event>
# Expected env: WS_ROOT, optionally WS_PROJECT, WS_BRANCH, WS_SITE, WS_DIR, WS_URL, WS_DB
_run_hook() {
    local event="$1"
    local root="$2"
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

# ── CREATE ──

cmd_create() {
    local branch_name="${1:?Usage: ws create <branch-name|pr:NUMBER>}"
    local secure="${2:-}"
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

    local sname
    sname="$(site_name "$branch_name")"
    local wt_path
    wt_path="$(worktree_path "$branch_name")"

    if [[ -d "$wt_path" ]]; then
        error "Workspace '$sname' already exists: $wt_path"
        exit 1
    fi

    header "Creating workspace: $sname"

    # Ensure .worktrees is in .gitignore
    if ! grep -qx "$WORKTREES_DIR" "$root/.gitignore" 2>/dev/null; then
        echo "$WORKTREES_DIR" >> "$root/.gitignore"
        success ".worktrees added to .gitignore"
    fi

    # Create the worktree
    info "Creating worktree on branch '$branch_name'..."
    cd "$root"
    git worktree add "$wt_path" -b "$branch_name" 2>/dev/null || \
    git worktree add "$wt_path" "$branch_name"
    success "Worktree created: $wt_path"

    # Export hook context (available to pre-create and onwards)
    local proto
    proto="$(site_protocol "$sname")"
    [[ "$secure" == "--secure" ]] && proto="https"
    export WS_PROJECT="$(basename "$root")"
    export WS_BRANCH="$branch_name"
    export WS_SITE="$sname"
    export WS_DIR="$wt_path"
    export WS_URL="${proto}://${sname}.test"
    export WS_ROOT="$root"

    # ── Auto-detection and setup ──
    cd "$wt_path"
    _run_hook "pre-create" "$root"
    _setup_env "$root" "$sname" "$secure"
    _setup_composer
    _setup_npm
    _setup_database "$branch_name" "$root"
    # WS_DB is set by _setup_database if applicable
    _setup_herd "$sname" "$secure" "$wt_path"
    _setup_vite
    _clear_cache
    _run_hook "post-create" "$root"

    # ── Post-creation summary ──
    proto="$(site_protocol "$sname")"
    local url="${proto}://${sname}.test"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓${NC} ${BOLD}Workspace ready!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}URL${NC}       ${CYAN}${url}${NC}"
    echo -e "  ${BOLD}Branch${NC}    ${branch_name}"
    echo -e "  ${BOLD}Path${NC}      ${DIM}${wt_path}${NC}"

    # Show DB if configured
    if [[ -f "$wt_path/.env" ]]; then
        local ws_db
        ws_db=$(grep "^DB_DATABASE=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        if [[ -n "$ws_db" ]]; then
            echo -e "  ${BOLD}Database${NC}  ${ws_db}"
        fi
    fi

    echo ""
    echo -e "  ${DIM}Get started:${NC}           cd ${wt_path}"
    echo -e "  ${DIM}Launch Claude Code:${NC}   ws run"
    echo -e "  ${DIM}Open in browser:${NC}      ws preview"
    echo ""
}

# ── SETUP HELPERS ──

_setup_env() {
    local root="$1"
    local sname="$2"
    local secure="${3:-}"

    # Determine protocol
    local proto="http"
    if [[ "$secure" == "--secure" ]]; then
        proto="https"
    fi

    if [[ -f "$root/.env" ]]; then
        # Copy .env from main project (more reliable than .env.example)
        cp "$root/.env" .env
        success ".env copied from main project"
    elif [[ -f ".env.example" ]]; then
        cp .env.example .env
        success ".env created from .env.example"
    fi

    if [[ ! -f ".env" ]]; then
        warn "No .env found"
        return 0
    fi

    # APP_URL
    sed -i '' "s|^APP_URL=.*|APP_URL=${proto}://${sname}.test|" .env 2>/dev/null || true

    # SESSION_DOMAIN
    if grep -q "^SESSION_DOMAIN=" .env 2>/dev/null; then
        sed -i '' "s|^SESSION_DOMAIN=.*|SESSION_DOMAIN=${sname}.test|" .env 2>/dev/null || true
    else
        echo "SESSION_DOMAIN=${sname}.test" >> .env
    fi

    # SANCTUM_STATEFUL_DOMAINS (if Sanctum is used)
    if grep -q "sanctum" composer.json 2>/dev/null; then
        if grep -q "^SANCTUM_STATEFUL_DOMAINS=" .env 2>/dev/null; then
            # Append the worktree domain to the existing list
            local current_domains
            current_domains=$(grep "^SANCTUM_STATEFUL_DOMAINS=" .env | cut -d= -f2 | tr -d '"' | tr -d "'")
            if [[ -n "$current_domains" ]]; then
                sed -i '' "s|^SANCTUM_STATEFUL_DOMAINS=.*|SANCTUM_STATEFUL_DOMAINS=${current_domains},${sname}.test|" .env 2>/dev/null || true
            else
                sed -i '' "s|^SANCTUM_STATEFUL_DOMAINS=.*|SANCTUM_STATEFUL_DOMAINS=${sname}.test|" .env 2>/dev/null || true
            fi
        else
            echo "SANCTUM_STATEFUL_DOMAINS=${sname}.test" >> .env
        fi
        success "SANCTUM_STATEFUL_DOMAINS updated"
    fi

    # SESSION_SECURE_COOKIE
    if [[ "$proto" == "http" ]]; then
        if grep -q "^SESSION_SECURE_COOKIE=" .env 2>/dev/null; then
            sed -i '' "s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=false|" .env 2>/dev/null || true
        else
            echo "SESSION_SECURE_COOKIE=false" >> .env
        fi
    else
        if grep -q "^SESSION_SECURE_COOKIE=" .env 2>/dev/null; then
            sed -i '' "s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=true|" .env 2>/dev/null || true
        else
            echo "SESSION_SECURE_COOKIE=true" >> .env
        fi
    fi

    # Generate APP_KEY if Laravel and key is empty
    if [[ -f "artisan" ]]; then
        local current_key
        current_key=$(grep "^APP_KEY=" .env 2>/dev/null | cut -d= -f2)
        if [[ -z "$current_key" || "$current_key" == "base64:" ]]; then
            php artisan key:generate --quiet 2>/dev/null && success "APP_KEY generated" || true
        fi
    fi

    # Unique Vite port per workspace (avoids npm run dev collisions)
    local vite_port
    vite_port=$(_hash_port "$sname")
    if grep -q "^VITE_PORT=" .env 2>/dev/null; then
        sed -i '' "s|^VITE_PORT=.*|VITE_PORT=${vite_port}|" .env 2>/dev/null || true
    else
        echo "VITE_PORT=${vite_port}" >> .env
    fi
    success "VITE_PORT=${vite_port} (unique per workspace)"

    success ".env configured (APP_URL=${proto}://${sname}.test)"
}

_setup_composer() {
    if [[ ! -f "composer.json" ]]; then
        return 0
    fi

    if [[ ! -d "vendor" ]]; then
        info "Installing Composer dependencies..."
        composer install --quiet --no-interaction 2>/dev/null && \
            success "Composer install done" || \
            warn "Composer install failed — do it manually"
    fi
}

_setup_npm() {
    if [[ ! -f "package.json" ]]; then
        return 0
    fi

    if [[ ! -d "node_modules" ]]; then
        info "Installing NPM dependencies..."
        npm install --silent 2>/dev/null && \
            success "NPM install done" || \
            warn "NPM install failed — do it manually"
    fi
}

_setup_database() {
    local branch_name="$1"
    local root="${2:-}"

    if [[ ! -f ".env" || ! -f "artisan" ]]; then
        return 0
    fi

    # Read DB config from main project .env (before our modifications)
    local source_env="${root:+$root/.env}"
    [[ -z "$source_env" || ! -f "$source_env" ]] && source_env=".env"

    local original_db
    original_db=$(grep "^DB_DATABASE=" "$source_env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")

    if [[ -z "$original_db" ]]; then
        return 0
    fi

    local branch_slug
    branch_slug="$(slugify "$branch_name")"
    local workspace_db="${original_db}_${branch_slug//-/_}"

    # Update .env with the new DB
    sed -i '' "s|^DB_DATABASE=.*|DB_DATABASE=$workspace_db|" .env 2>/dev/null || true
    export WS_DB="$workspace_db"

    # Read credentials from workspace .env, with Laravel defaults
    local db_connection db_user db_pass db_host db_port
    db_connection=$(grep "^DB_CONNECTION=" .env | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    db_user=$(grep "^DB_USERNAME=" .env | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    db_pass=$(grep "^DB_PASSWORD=" .env | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    db_host=$(grep "^DB_HOST=" .env | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    db_port=$(grep "^DB_PORT=" .env | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    db_user="${db_user:-root}"
    db_host="${db_host:-127.0.0.1}"

    case "${db_connection:-}" in
        mysql|mariadb)
            if command -v mysql &>/dev/null; then
                if mysql \
                    -u"$db_user" \
                    ${db_pass:+-p"$db_pass"} \
                    -h"$db_host" \
                    ${db_port:+-P"$db_port"} \
                    -e "CREATE DATABASE IF NOT EXISTS \`$workspace_db\`;" 2>/dev/null; then
                    success "Database '$workspace_db' created (MySQL)"
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
                local psql_args=(-U "$db_user" -h "$db_host")
                [[ -n "${db_port:-}" ]] && psql_args+=(-p "$db_port")

                # Connect to source DB to create the new one
                if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d "$original_db" \
                    -c "CREATE DATABASE \"$workspace_db\";" 2>/dev/null; then
                    success "Database '$workspace_db' created (PostgreSQL)"
                else
                    warn "Could not create database — do it manually"
                fi

                # Recreate the search_path (schema) if defined
                local search_path=""
                search_path=$(grep "^DB_SEARCH_PATH=" .env | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
                if [[ -n "$search_path" ]]; then
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
                touch "$db_path"
                success "SQLite file created"
            fi
            ;;
    esac

    # Run migrations
    info "Running migrations..."
    if php artisan migrate --quiet --no-interaction 2>/dev/null; then
        success "Migrations done"
    else
        warn "Migrations failed — do it manually"
    fi

    # Seed if DatabaseSeeder exists
    if [[ -f "database/seeders/DatabaseSeeder.php" ]]; then
        info "Running seeders..."
        if php artisan db:seed --quiet --no-interaction 2>/dev/null; then
            success "Seeders done"
        else
            warn "Seeders failed — do it manually"
        fi
    fi
}

_setup_herd() {
    local sname="$1"
    local secure="${2:-}"
    local wt_path="${3:-$PWD}"

    if ! command -v herd &>/dev/null; then
        warn "Herd not found in PATH"
        return 0
    fi

    info "Linking with Herd..."
    (cd "$wt_path" && herd link "$sname") 2>/dev/null && \
        success "Herd link: $sname.test" || \
        { warn "Herd link failed — do it manually"; return 0; }

    # Secure if requested
    if [[ "$secure" == "--secure" ]]; then
        herd secure "$sname" 2>/dev/null && \
            success "Herd secure: https://$sname.test" || \
            warn "Herd secure failed — do it manually"
    fi
}

_setup_vite() {
    if [[ ! -f "vite.config.js" && ! -f "vite.config.ts" ]]; then
        return 0
    fi

    local vite_config
    vite_config="$(ls vite.config.* 2>/dev/null | head -1)"

    if [[ -z "$vite_config" ]]; then
        return 0
    fi

    # Check if host and cors are configured
    if ! grep -q "host:" "$vite_config" 2>/dev/null; then
        info "Adding host: 'localhost', cors: true, port: from VITE_PORT to $vite_config..."
        # Inject server config into vite file
        if grep -q "server:" "$vite_config" 2>/dev/null; then
            # server: already exists, check/add host, cors and port
            if ! grep -q "host:" "$vite_config" 2>/dev/null; then
                sed -i '' "/server:/a\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\            port: Number(process.env.VITE_PORT) || 5173," "$vite_config" 2>/dev/null || true
            fi
        else
            # Add a server block after defineConfig
            sed -i '' "/plugins:/i\\
\\        server: {\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\            port: Number(process.env.VITE_PORT) || 5173,\\
\\        }," "$vite_config" 2>/dev/null || true
        fi
        success "vite.config: host: 'localhost', cors: true, port from VITE_PORT"
    elif ! grep -q "process.env.VITE_PORT" "$vite_config" 2>/dev/null; then
        # host already configured but no VITE_PORT wiring — add port line next to host
        info "Adding port: Number(process.env.VITE_PORT) || 5173 to $vite_config..."
        sed -i '' "/host: 'localhost'/a\\
\\            port: Number(process.env.VITE_PORT) || 5173," "$vite_config" 2>/dev/null || true
        success "vite.config: port wired to VITE_PORT"
    fi

    # Kill existing Vite processes that might interfere
    if pgrep -f "node.*vite" &>/dev/null; then
        warn "Vite processes are running."
        read -rp "Kill them to avoid port conflicts? (y/N): " kill_vite
        if [[ "$kill_vite" =~ ^[yY]$ ]]; then
            pkill -f "node.*vite" 2>/dev/null || true
            rm -f public/hot 2>/dev/null || true
            success "Vite processes killed"
        fi
    fi
}

_clear_cache() {
    if [[ ! -f "artisan" ]]; then
        return 0
    fi

    info "Clearing Laravel caches..."
    php artisan config:clear --quiet 2>/dev/null || true
    php artisan cache:clear --quiet 2>/dev/null || true
    php artisan route:clear --quiet 2>/dev/null || true
    php artisan view:clear --quiet 2>/dev/null || true
    success "Laravel caches cleared"
}

# ── RUN ──

cmd_run() {
    local wt_path

    if [[ -n "${1:-}" ]]; then
        wt_path="$(worktree_path "$1")"
        if [[ ! -d "$wt_path" ]]; then
            error "Workspace '$(site_name "$1")' not found."
            exit 1
        fi
    elif detect_current_worktree &>/dev/null; then
        wt_path="$(detect_current_worktree)"
    else
        # At project root: offer available worktrees
        local root
        root="$(find_project_root)"
        local wt_dir="$root/$WORKTREES_DIR"

        if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
            error "No workspace found. Use: ws create <branch-name>"
            exit 1
        fi

        header "Available workspaces:"
        local i=1
        local workspaces=()
        for dir in "$wt_dir"/*/; do
            [[ -d "$dir" ]] || continue
            local name
            name="$(basename "$dir")"
            workspaces+=("$name")
            local branch
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")
            echo -e "  ${CYAN}$i)${NC} $name ${DIM}($branch)${NC}"
            ((i++))
        done

        echo ""
        read -rp "Choose a workspace (1-${#workspaces[@]}): " choice

        if [[ "$choice" -ge 1 && "$choice" -le "${#workspaces[@]}" ]] 2>/dev/null; then
            local selected="${workspaces[$((choice-1))]}"
            wt_path="$wt_dir/$selected"
        else
            error "Invalid choice."
            exit 1
        fi
    fi

    local name
    name="$(basename "$wt_path")"
    info "Launching Claude Code in '$name'..."
    echo -e "${DIM}─────────────────────────────────────${NC}"

    if ! command -v claude &>/dev/null; then
        error "Claude Code is not installed or not in PATH."
        exit 1
    fi

    cd "$wt_path"
    exec claude
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

        # Branch
        branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")

        # Uncommitted changes
        if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
            dirty_flag=" ${YELLOW}●${NC}"
        else
            dirty_flag=""
        fi

        # Commits ahead
        commits_ahead=$(git -C "$dir" rev-list --count "$default_branch..HEAD" 2>/dev/null || echo "?")

        # DB
        if [[ -f "$dir/.env" ]]; then
            local ws_db
            ws_db=$(grep "^DB_DATABASE=" "$dir/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
            if [[ -n "$ws_db" ]]; then
                db_status="${GREEN}✓${NC} DB"
            else
                db_status="${DIM}– DB${NC}"
            fi
        else
            db_status="${DIM}– DB${NC}"
        fi

        # Herd + protocol
        local proto="http"
        if detect_herd_secure "$name"; then
            proto="https"
        fi

        if command -v herd &>/dev/null && herd links 2>/dev/null | grep -q "$name"; then
            herd_status="${GREEN}✓${NC} Herd"
        else
            herd_status="${DIM}– Herd${NC}"
        fi

        url_display="${proto}://$name.test"

        echo -e "  ${BOLD}$name${NC}  ${DIM}($branch)${NC}${dirty_flag}  ${CYAN}+$commits_ahead${NC}  $db_status  $herd_status  ${DIM}→ $url_display${NC}"
    done

    echo ""
}

# ── PREVIEW ──

cmd_preview() {
    local sname

    if [[ -n "${1:-}" ]]; then
        sname="$(site_name "$1")"
    elif detect_current_worktree &>/dev/null; then
        sname="$(basename "$(detect_current_worktree)")"
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
    local branch_name="${1:-}"
    local root
    root="$(find_project_root)"

    # Detect the workspace
    local wt_path sname wt_branch

    if [[ -n "$branch_name" ]]; then
        sname="$(site_name "$branch_name")"
        wt_path="$(worktree_path "$branch_name")"
    elif detect_current_worktree &>/dev/null; then
        wt_path="$(detect_current_worktree)"
        sname="$(basename "$wt_path")"
    else
        # Show available worktrees
        local wt_dir="$root/$WORKTREES_DIR"
        if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
            error "No workspace found."
            exit 1
        fi

        header "Which workspace to finish?"
        local i=1
        local workspaces=()
        for dir in "$wt_dir"/*/; do
            [[ -d "$dir" ]] || continue
            local name
            name="$(basename "$dir")"
            workspaces+=("$name")
            local branch
            branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")
            echo -e "  ${CYAN}$i)${NC} $name ${DIM}($branch)${NC}"
            ((i++))
        done
        echo ""
        read -rp "Choose a workspace (1-${#workspaces[@]}): " choice
        if [[ "$choice" -ge 1 && "$choice" -le "${#workspaces[@]}" ]] 2>/dev/null; then
            sname="${workspaces[$((choice-1))]}"
            wt_path="$wt_dir/$sname"
        else
            error "Invalid choice."
            exit 1
        fi
    fi

    if [[ ! -d "$wt_path" ]]; then
        error "Workspace '$sname' not found."
        exit 1
    fi

    wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)

    # Check for uncommitted changes
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

    # Commit uncommitted changes
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        echo ""
        read -rp "Commit message: " commit_msg
        git add -A
        git commit -m "$commit_msg"
        success "Changes committed"
    fi

    # Push
    info "Pushing branch '$wt_branch'..."
    git push -u origin "$wt_branch" 2>/dev/null && \
        success "Branch pushed" || \
        { error "Push failed."; exit 1; }

    # Create the PR
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
            2)
                pr_body=$(git log "$default_branch..$wt_branch" --pretty=format:"- %s" 2>/dev/null)
                ;;
            3)
                pr_body=""
                ;;
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

    # Check for uncommitted changes
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

    header "Merging '$wt_branch' into current branch"

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

    # Kill Vite if running in the worktree
    local vite_pids
    vite_pids=$(pgrep -f "node.*vite.*${sname}" 2>/dev/null || true)
    if [[ -n "$vite_pids" ]]; then
        echo "$vite_pids" | xargs kill 2>/dev/null || true
        success "Vite processes killed"
    fi

    # Unlink Herd
    if command -v herd &>/dev/null; then
        herd unsecure "$sname" 2>/dev/null || true
        herd unlink "$sname" 2>/dev/null && \
            success "Herd unlink: $sname" || true
    fi

    # Drop the DB
    if [[ "$keep_db" == "--keep-db" ]]; then
        info "Database kept"
    elif [[ -f "$wt_path/.env" ]]; then
        local ws_db db_connection db_user db_pass db_host db_port
        ws_db=$(grep "^DB_DATABASE=" "$wt_path/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        db_connection=$(grep "^DB_CONNECTION=" "$wt_path/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        db_user=$(grep "^DB_USERNAME=" "$wt_path/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        db_pass=$(grep "^DB_PASSWORD=" "$wt_path/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        db_host=$(grep "^DB_HOST=" "$wt_path/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        db_port=$(grep "^DB_PORT=" "$wt_path/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
        db_user="${db_user:-root}"
        db_host="${db_host:-127.0.0.1}"

        if [[ -n "$ws_db" ]]; then
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
                        local psql_args=(-U "$db_user" -h "$db_host")
                        [[ -n "${db_port:-}" ]] && psql_args+=(-p "$db_port")

                        if PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                            -c "DROP DATABASE IF EXISTS \"$ws_db\";" 2>/dev/null; then
                            success "Database '$ws_db' dropped"
                        else
                            warn "Could not drop database '$ws_db'"
                        fi
                    fi
                    ;;
            esac
        fi
    fi

    # Remove the worktree (make sure we're not inside it)
    cd "$root"
    if git worktree remove "$wt_path" --force 2>/dev/null; then
        success "Worktree removed"
    else
        rm -rf "$wt_path"
        git worktree prune 2>/dev/null || true
        success "Worktree removed (force)"
    fi

    # Delete the branch
    if [[ -n "$wt_branch" ]]; then
        git branch -d "$wt_branch" 2>/dev/null && \
            success "Branch '$wt_branch' deleted" || \
            warn "Branch '$wt_branch' not deleted (not merged yet?)"
    fi

    echo ""
    success "Workspace '$sname' cleaned up."
}

# ── DESTROY (alias rapide) ──

cmd_destroy() {
    local branch_name="" keep_db=""
    for arg in "$@"; do
        case "$arg" in
            --keep-db) keep_db="--keep-db" ;;
            *) branch_name="$arg" ;;
        esac
    done

    if [[ -z "$branch_name" ]]; then
        error "Usage: ws destroy <branch-name> [--keep-db]"
        exit 1
    fi

    local root
    root="$(find_project_root)"
    local sname
    sname="$(site_name "$branch_name")"
    local wt_path
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
    read -rp "Confirm? (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || exit 0

    export WS_PROJECT="$(basename "$root")"
    export WS_BRANCH="$wt_branch"
    export WS_SITE="$sname"
    export WS_DIR="$wt_path"
    export WS_ROOT="$root"
    _run_hook "pre-destroy" "$root"

    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root" "$keep_db"
}

# ── HELP ──

cmd_help() {
    echo ""
    echo -e "${BOLD}ws${NC} v$VERSION — Workspace manager for Laravel + Claude Code"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ws create <branch|pr:N> [--secure]  Create a workspace (branch or GitHub PR)"
    echo -e "  ws run [branch]                     Launch Claude Code in the workspace"
    echo -e "  ws status                           Show all workspaces and their state"
    echo -e "  ws preview [branch]                 Open the site in the browser"
    echo -e "  ws finish [branch]                  Finish work (PR / merge / abandon)"
    echo -e "  ws destroy <branch> [--keep-db]     Delete the workspace and Herd link"
    echo -e "  ws help                             Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  ${DIM}cd ~/Sites/my-project${NC}"
    echo -e "  ws create feature/auth                ${DIM}# HTTP by default${NC}"
    echo -e "  ws create feature/auth --secure       ${DIM}# HTTPS with herd secure${NC}"
    echo -e "  ws create pr:42                       ${DIM}# check out PR #42 in a worktree${NC}"
    echo -e "  ws run feature/auth"
    echo -e "  ws run                                ${DIM}# from the worktree, or interactive choice${NC}"
    echo -e "  ws status"
    echo -e "  ws preview feature/auth"
    echo -e "  ws finish                             ${DIM}# guided workflow: PR, merge, or abandon${NC}"
    echo -e "  ws destroy feature/auth"
    echo ""
    echo -e "${BOLD}Naming:${NC}"
    echo -e "  Herd sites use the format ${CYAN}project-branch.test${NC}"
    echo -e "  E.g.: project ${DIM}my-app${NC} + branch ${DIM}feature/login${NC} → ${CYAN}my-app-feature-login.test${NC}"
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
        run)     cmd_run "$@" ;;
        status)  cmd_status "$@" ;;
        preview) cmd_preview "$@" ;;
        finish)  cmd_finish "$@" ;;
        merge)   cmd_finish "$@" ;;  # alias
        destroy) cmd_destroy "$@" ;;
        help|-h|--help) cmd_help ;;
        *)
            error "Unknown command: $command"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
