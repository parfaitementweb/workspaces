#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ws — Workspace manager for Laravel + Claude Code
# Crée des worktrees isolés avec Herd, DB, et dépendances auto
# ─────────────────────────────────────────────

VERSION="2.0.0"
WORKTREES_DIR=".worktrees"

# ── Couleurs ──
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

# Trouve la racine du projet git le plus proche
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    error "Pas de dépôt git trouvé dans l'arborescence."
    exit 1
}

# Nom du projet depuis le dossier
project_name() {
    basename "$(find_project_root)"
}

# Slug propre pour le nom de branche (feature/auth → feature-auth)
slugify() {
    echo "$1" | sed 's/[\/]/-/g' | sed 's/[^a-zA-Z0-9._-]/-/g' | tr '[:upper:]' '[:lower:]'
}

# Nom complet du site: projet-branche
site_name() {
    local proj
    proj="$(project_name)"
    local slug
    slug="$(slugify "$1")"
    echo "${proj}-${slug}"
}

# Chemin du worktree (utilise le site_name pour le dossier)
worktree_path() {
    local root
    root="$(find_project_root)"
    local sname
    sname="$(site_name "$1")"
    echo "$root/$WORKTREES_DIR/$sname"
}

# Vérifie qu'on est dans un worktree et retourne son chemin
detect_current_worktree() {
    if [[ "$PWD" == *"$WORKTREES_DIR"* ]]; then
        echo "$PWD"
        return 0
    fi
    return 1
}

# Détecte la branche par défaut du repo (main, master, develop...)
detect_default_branch() {
    local root
    root="$(find_project_root)"
    local branch
    branch=$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [[ -z "$branch" ]]; then
        # Fallback: essayer main, puis master
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

# Détecte si le site Herd utilise HTTPS (vérifie les certificats Herd)
detect_herd_secure() {
    local sname="$1"
    # Herd stocke les certificats dans ~/.config/herd/ssl
    if [[ -f "$HOME/.config/herd/ssl/${sname}.test.crt" ]]; then
        return 0  # HTTPS
    fi
    return 1  # HTTP
}

# Retourne le protocol à utiliser pour le site
site_protocol() {
    local sname="$1"
    if detect_herd_secure "$sname"; then
        echo "https"
    else
        echo "http"
    fi
}

# ── CREATE ──

cmd_create() {
    local branch_name="${1:?Usage: ws create <branch-name>}"
    local secure="${2:-}"  # --secure optionnel
    local root
    root="$(find_project_root)"
    local sname
    sname="$(site_name "$branch_name")"
    local wt_path
    wt_path="$(worktree_path "$branch_name")"

    if [[ -d "$wt_path" ]]; then
        error "Le workspace '$sname' existe déjà: $wt_path"
        exit 1
    fi

    header "Création du workspace: $sname"

    # S'assurer que .worktrees est dans le .gitignore
    if ! grep -qx "$WORKTREES_DIR" "$root/.gitignore" 2>/dev/null; then
        echo "$WORKTREES_DIR" >> "$root/.gitignore"
        success ".worktrees ajouté au .gitignore"
    fi

    # Créer le worktree
    info "Création du worktree sur branche '$branch_name'..."
    cd "$root"
    git worktree add "$wt_path" -b "$branch_name" 2>/dev/null || \
    git worktree add "$wt_path" "$branch_name"
    success "Worktree créé: $wt_path"

    # ── Auto-détection et setup ──
    cd "$wt_path"
    _setup_env "$root" "$sname" "$secure"
    _setup_composer
    _setup_npm
    _setup_database "$sname" "$root"
    _setup_herd "$sname" "$secure" "$wt_path"
    _setup_vite
    _clear_cache

    # ── Récap post-création ──
    local proto
    proto="$(site_protocol "$sname")"
    local url="${proto}://${sname}.test"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓${NC} ${BOLD}Workspace prêt!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}URL${NC}       ${CYAN}${url}${NC}"
    echo -e "  ${BOLD}Branche${NC}   ${branch_name}"
    echo -e "  ${BOLD}Path${NC}      ${DIM}${wt_path}${NC}"

    # Afficher la DB si configurée
    if [[ -f "$wt_path/.env" ]]; then
        local ws_db
        ws_db=$(grep "^DB_DATABASE=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        if [[ -n "$ws_db" ]]; then
            echo -e "  ${BOLD}Database${NC}  ${ws_db}"
        fi
    fi

    echo ""
    echo -e "  ${DIM}Commencer :${NC}           cd ${wt_path}"
    echo -e "  ${DIM}Lancer Claude Code :${NC}  ws run"
    echo -e "  ${DIM}Ouvrir le site :${NC}      ws preview"
    echo ""
}

# ── SETUP HELPERS ──

_setup_env() {
    local root="$1"
    local sname="$2"
    local secure="${3:-}"

    # Déterminer le protocol
    local proto="http"
    if [[ "$secure" == "--secure" ]]; then
        proto="https"
    fi

    if [[ -f "$root/.env" ]]; then
        # Copier le .env du projet principal (plus fiable que .env.example)
        cp "$root/.env" .env
        success ".env copié depuis le projet principal"
    elif [[ -f ".env.example" ]]; then
        cp .env.example .env
        success ".env créé depuis .env.example"
    fi

    if [[ ! -f ".env" ]]; then
        warn "Pas de .env trouvé"
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

    # SANCTUM_STATEFUL_DOMAINS (si Sanctum est utilisé)
    if grep -q "sanctum" composer.json 2>/dev/null; then
        if grep -q "^SANCTUM_STATEFUL_DOMAINS=" .env 2>/dev/null; then
            # Ajouter le domaine du worktree à la liste existante
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
        success "SANCTUM_STATEFUL_DOMAINS mis à jour"
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

    # Générer APP_KEY si c'est Laravel et que la clé est vide
    if [[ -f "artisan" ]]; then
        local current_key
        current_key=$(grep "^APP_KEY=" .env 2>/dev/null | cut -d= -f2)
        if [[ -z "$current_key" || "$current_key" == "base64:" ]]; then
            php artisan key:generate --quiet 2>/dev/null && success "APP_KEY générée" || true
        fi
    fi

    success ".env configuré (APP_URL=${proto}://${sname}.test)"
}

_setup_composer() {
    if [[ ! -f "composer.json" ]]; then
        return 0
    fi

    if [[ ! -d "vendor" ]]; then
        info "Installation des dépendances Composer..."
        composer install --quiet --no-interaction 2>/dev/null && \
            success "Composer install terminé" || \
            warn "Composer install a échoué — à faire manuellement"
    fi
}

_setup_npm() {
    if [[ ! -f "package.json" ]]; then
        return 0
    fi

    if [[ ! -d "node_modules" ]]; then
        info "Installation des dépendances NPM..."
        npm install --silent 2>/dev/null && \
            success "NPM install terminé" || \
            warn "NPM install a échoué — à faire manuellement"
    fi
}

_setup_database() {
    local sname="$1"
    local root="${2:-}"

    if [[ ! -f ".env" || ! -f "artisan" ]]; then
        return 0
    fi

    # Lire la config DB depuis le .env du projet principal (avant nos modifications)
    local source_env="${root:+$root/.env}"
    [[ -z "$source_env" || ! -f "$source_env" ]] && source_env=".env"

    local original_db
    original_db=$(grep "^DB_DATABASE=" "$source_env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")

    if [[ -z "$original_db" ]]; then
        return 0
    fi

    local workspace_db="${original_db}_${sname//-/_}"

    # Mettre à jour le .env avec la nouvelle DB
    sed -i '' "s|^DB_DATABASE=.*|DB_DATABASE=$workspace_db|" .env 2>/dev/null || true

    # Lire les credentials depuis le .env du workspace (déjà copié)
    local db_connection db_user db_pass db_host db_port
    db_connection=$(grep "^DB_CONNECTION=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    db_user=$(grep "^DB_USERNAME=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    db_pass=$(grep "^DB_PASSWORD=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    db_host=$(grep "^DB_HOST=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    db_port=$(grep "^DB_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")

    case "$db_connection" in
        mysql|mariadb)
            if command -v mysql &>/dev/null; then
                mysql \
                    -u"${db_user:-root}" \
                    ${db_pass:+-p"$db_pass"} \
                    ${db_host:+-h"$db_host"} \
                    ${db_port:+-P"$db_port"} \
                    -e "CREATE DATABASE IF NOT EXISTS \`$workspace_db\`;" 2>/dev/null && \
                    success "Base de données '$workspace_db' créée (MySQL)" || \
                    warn "Impossible de créer la DB — à faire manuellement"
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
                local psql_args=()
                [[ -n "$db_user" ]] && psql_args+=(-U "$db_user")
                [[ -n "$db_host" ]] && psql_args+=(-h "$db_host")
                [[ -n "$db_port" ]] && psql_args+=(-p "$db_port")

                # Se connecter à la DB source pour créer la nouvelle
                PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d "$original_db" \
                    -c "CREATE DATABASE \"$workspace_db\";" 2>/dev/null && \
                    success "Base de données '$workspace_db' créée (PostgreSQL)" || \
                    warn "Impossible de créer la DB — à faire manuellement"

                # Recréer le search_path (schema) si défini
                local search_path
                search_path=$(grep "^DB_SEARCH_PATH=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
                if [[ -n "$search_path" ]]; then
                    PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d "$workspace_db" \
                        -c "CREATE SCHEMA IF NOT EXISTS \"$search_path\";" 2>/dev/null && \
                        success "Schema '$search_path' créé" || \
                        warn "Impossible de créer le schema — à faire manuellement"
                fi
            else
                warn "psql non trouvé — DB PostgreSQL à créer manuellement"
            fi
            ;;
        sqlite)
            local db_path="database/database.sqlite"
            if [[ ! -f "$db_path" ]]; then
                touch "$db_path"
                success "Fichier SQLite créé"
            fi
            ;;
    esac

    # Lancer les migrations
    info "Exécution des migrations..."
    php artisan migrate --quiet --no-interaction 2>/dev/null && \
        success "Migrations exécutées" || \
        warn "Migrations échouées — à faire manuellement"

    # Seeder si DatabaseSeeder existe
    if [[ -f "database/seeders/DatabaseSeeder.php" ]]; then
        info "Exécution des seeders..."
        php artisan db:seed --quiet --no-interaction 2>/dev/null && \
            success "Seeders exécutés" || \
            warn "Seeders échoués — à faire manuellement"
    fi
}

_setup_herd() {
    local sname="$1"
    local secure="${2:-}"
    local wt_path="${3:-$PWD}"

    if ! command -v herd &>/dev/null; then
        warn "Herd non détecté dans le PATH"
        return 0
    fi

    info "Liaison avec Herd..."
    (cd "$wt_path" && herd link "$sname") 2>/dev/null && \
        success "Herd link: $sname.test" || \
        { warn "Herd link a échoué — à faire manuellement"; return 0; }

    # Sécuriser si demandé
    if [[ "$secure" == "--secure" ]]; then
        herd secure "$sname" 2>/dev/null && \
            success "Herd secure: https://$sname.test" || \
            warn "Herd secure a échoué — à faire manuellement"
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

    # Vérifier si host et cors sont configurés
    if ! grep -q "host:" "$vite_config" 2>/dev/null; then
        info "Ajout de host: 'localhost' et cors: true dans $vite_config..."
        # Injecter la config server dans le fichier vite
        if grep -q "server:" "$vite_config" 2>/dev/null; then
            # server: existe déjà, vérifier/ajouter host et cors
            if ! grep -q "host:" "$vite_config" 2>/dev/null; then
                sed -i '' "/server:/a\\
\\            host: 'localhost',\\
\\            cors: true," "$vite_config" 2>/dev/null || true
            fi
        else
            # Ajouter un bloc server après defineConfig
            sed -i '' "/plugins:/i\\
\\        server: {\\
\\            host: 'localhost',\\
\\            cors: true,\\
\\        }," "$vite_config" 2>/dev/null || true
        fi
        success "vite.config: host: 'localhost', cors: true"
    fi

    # Tuer les process Vite existants qui pourraient interférer
    if pgrep -f "node.*vite" &>/dev/null; then
        warn "Des process Vite sont en cours d'exécution."
        read -rp "Les tuer pour éviter les conflits de port ? (y/N): " kill_vite
        if [[ "$kill_vite" =~ ^[yY]$ ]]; then
            pkill -f "node.*vite" 2>/dev/null || true
            rm -f public/hot 2>/dev/null || true
            success "Process Vite arrêtés"
        fi
    fi
}

_clear_cache() {
    if [[ ! -f "artisan" ]]; then
        return 0
    fi

    info "Nettoyage des caches Laravel..."
    php artisan config:clear --quiet 2>/dev/null || true
    php artisan cache:clear --quiet 2>/dev/null || true
    php artisan route:clear --quiet 2>/dev/null || true
    php artisan view:clear --quiet 2>/dev/null || true
    success "Caches Laravel nettoyés"
}

# ── RUN ──

cmd_run() {
    local wt_path

    if [[ -n "${1:-}" ]]; then
        wt_path="$(worktree_path "$1")"
        if [[ ! -d "$wt_path" ]]; then
            error "Workspace '$(site_name "$1")' introuvable."
            exit 1
        fi
    elif detect_current_worktree &>/dev/null; then
        wt_path="$(detect_current_worktree)"
    else
        # À la racine: proposer les worktrees disponibles
        local root
        root="$(find_project_root)"
        local wt_dir="$root/$WORKTREES_DIR"

        if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
            error "Aucun workspace trouvé. Utilise: ws create <branch-name>"
            exit 1
        fi

        header "Workspaces disponibles:"
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
        read -rp "Choisis un workspace (1-${#workspaces[@]}): " choice

        if [[ "$choice" -ge 1 && "$choice" -le "${#workspaces[@]}" ]] 2>/dev/null; then
            local selected="${workspaces[$((choice-1))]}"
            wt_path="$wt_dir/$selected"
        else
            error "Choix invalide."
            exit 1
        fi
    fi

    local name
    name="$(basename "$wt_path")"
    info "Lancement de Claude Code dans '$name'..."
    echo -e "${DIM}─────────────────────────────────────${NC}"

    if ! command -v claude &>/dev/null; then
        error "Claude Code n'est pas installé ou pas dans le PATH."
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
        echo -e "  ${DIM}Aucun workspace.${NC}"
        echo -e "  ${DIM}Utilise: ws create <branch-name>${NC}"
        return 0
    fi

    for dir in "$wt_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local name branch commits_ahead db_status herd_status url_display dirty_flag
        name="$(basename "$dir")"

        # Branche
        branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")

        # Changements non commités
        if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
            dirty_flag=" ${YELLOW}●${NC}"
        else
            dirty_flag=""
        fi

        # Commits d'avance
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
        error "Usage: ws preview <branch-name> (ou lance depuis un worktree)"
        exit 1
    fi

    local proto
    proto="$(site_protocol "$sname")"
    local url="${proto}://$sname.test"
    info "Ouverture de $url..."
    open "$url"
}

# ── FINISH ──

cmd_finish() {
    local branch_name="${1:-}"
    local root
    root="$(find_project_root)"

    # Détecter le workspace
    local wt_path sname wt_branch

    if [[ -n "$branch_name" ]]; then
        sname="$(site_name "$branch_name")"
        wt_path="$(worktree_path "$branch_name")"
    elif detect_current_worktree &>/dev/null; then
        wt_path="$(detect_current_worktree)"
        sname="$(basename "$wt_path")"
    else
        # Proposer les worktrees disponibles
        local wt_dir="$root/$WORKTREES_DIR"
        if [[ ! -d "$wt_dir" ]] || [[ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]]; then
            error "Aucun workspace trouvé."
            exit 1
        fi

        header "Quel workspace terminer ?"
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
        read -rp "Choisis un workspace (1-${#workspaces[@]}): " choice
        if [[ "$choice" -ge 1 && "$choice" -le "${#workspaces[@]}" ]] 2>/dev/null; then
            sname="${workspaces[$((choice-1))]}"
            wt_path="$wt_dir/$sname"
        else
            error "Choix invalide."
            exit 1
        fi
    fi

    if [[ ! -d "$wt_path" ]]; then
        error "Workspace '$sname' introuvable."
        exit 1
    fi

    wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)

    # Vérifier s'il y a des changements non commités
    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        warn "Changements non commités dans '$sname'."
    fi

    header "Terminer le workspace '$sname' ($wt_branch)"
    echo ""
    echo -e "  ${CYAN}1)${NC} Créer une PR depuis le worktree ${DIM}(recommandé)${NC}"
    echo -e "  ${CYAN}2)${NC} Merger dans la branche courante"
    echo -e "  ${CYAN}3)${NC} Abandonner les changements"
    echo ""
    read -rp "Choix (1-3): " finish_choice

    case "$finish_choice" in
        1) _finish_pr "$sname" "$wt_path" "$wt_branch" "$root" ;;
        2) _finish_merge "$sname" "$wt_path" "$wt_branch" "$root" ;;
        3) _finish_abandon "$sname" "$wt_path" "$wt_branch" "$root" ;;
        *)
            error "Choix invalide."
            exit 1
            ;;
    esac
}

_finish_pr() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    cd "$wt_path"

    # Commiter les changements non commités
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        echo ""
        read -rp "Message de commit: " commit_msg
        git add -A
        git commit -m "$commit_msg"
        success "Changements commités"
    fi

    # Push
    info "Push de la branche '$wt_branch'..."
    git push -u origin "$wt_branch" 2>/dev/null && \
        success "Branche pushée" || \
        { error "Push échoué."; exit 1; }

    # Créer la PR
    if command -v gh &>/dev/null; then
        local default_branch
        default_branch="$(detect_default_branch)"

        echo ""
        read -rp "Titre de la PR: " pr_title

        echo ""
        echo -e "  ${CYAN}1)${NC} Je rédige la description sur GitHub"
        echo -e "  ${CYAN}2)${NC} Générer depuis le diff"
        echo -e "  ${CYAN}3)${NC} Pas de description"
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
            success "PR créée!" || \
            warn "Création de PR échouée — crée-la manuellement sur GitHub"
    else
        warn "gh CLI non installé — crée la PR manuellement sur GitHub"
    fi

    echo ""
    read -rp "Supprimer le workspace maintenant ? (y/N): " cleanup
    if [[ "$cleanup" =~ ^[yY]$ ]]; then
        _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
    else
        info "Le workspace reste disponible. Utilise 'ws destroy' pour le supprimer plus tard."
    fi
}

_finish_merge() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    # Vérifier les changements non commités
    if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        warn "Il y a des changements non commités dans '$sname'."
        read -rp "Les commiter avant de merger ? (Y/n): " do_commit
        if [[ ! "$do_commit" =~ ^[nN]$ ]]; then
            cd "$wt_path"
            echo ""
            read -rp "Message de commit: " commit_msg
            git add -A
            git commit -m "$commit_msg"
            success "Changements commités"
        fi
    fi

    header "Merge de '$wt_branch' dans la branche courante"

    cd "$root"
    git merge "$wt_branch" --no-commit --no-ff && \
        success "Merge réussi (non commité — vérifie avec git status)" || \
        { error "Conflits détectés — résous-les manuellement."; exit 1; }

    echo ""
    read -rp "Supprimer le workspace ? (y/N): " cleanup
    if [[ "$cleanup" =~ ^[yY]$ ]]; then
        _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
    fi
}

_finish_abandon() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    echo -e "\n${RED}${BOLD}Abandon du workspace '$sname'${NC}"
    echo -e "  ${DIM}Tous les changements seront perdus.${NC}"
    echo ""
    read -rp "Confirmer ? (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || exit 0

    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
}

# ── CLEANUP (shared) ──

_cleanup_workspace() {
    local sname="$1" wt_path="$2" wt_branch="$3" root="$4"

    # Tuer Vite si en cours dans le worktree
    local vite_pids
    vite_pids=$(pgrep -f "node.*vite.*${sname}" 2>/dev/null || true)
    if [[ -n "$vite_pids" ]]; then
        echo "$vite_pids" | xargs kill 2>/dev/null || true
        success "Process Vite arrêtés"
    fi

    # Unlink Herd
    if command -v herd &>/dev/null; then
        herd unsecure "$sname" 2>/dev/null || true
        herd unlink "$sname" 2>/dev/null && \
            success "Herd unlink: $sname" || true
    fi

    # Supprimer la DB
    if [[ -f "$wt_path/.env" ]]; then
        local ws_db db_connection db_user db_pass db_host db_port
        ws_db=$(grep "^DB_DATABASE=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        db_connection=$(grep "^DB_CONNECTION=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        db_user=$(grep "^DB_USERNAME=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        db_pass=$(grep "^DB_PASSWORD=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        db_host=$(grep "^DB_HOST=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        db_port=$(grep "^DB_PORT=" "$wt_path/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")

        case "$db_connection" in
            mysql|mariadb)
                if command -v mysql &>/dev/null && [[ -n "$ws_db" ]]; then
                    mysql \
                        -u"${db_user:-root}" \
                        ${db_pass:+-p"$db_pass"} \
                        ${db_host:+-h"$db_host"} \
                        ${db_port:+-P"$db_port"} \
                        -e "DROP DATABASE IF EXISTS \`$ws_db\`;" 2>/dev/null && \
                        success "Base de données '$ws_db' supprimée" || true
                fi
                ;;
            pgsql)
                if [[ -n "$ws_db" ]]; then
                    local psql_cmd=""
                    if command -v psql &>/dev/null; then
                        psql_cmd="psql"
                    elif [[ -x "$HOME/Library/Application Support/Herd/bin/psql" ]]; then
                        psql_cmd="$HOME/Library/Application Support/Herd/bin/psql"
                    fi

                    if [[ -n "$psql_cmd" ]]; then
                        local psql_args=()
                        [[ -n "$db_user" ]] && psql_args+=(-U "$db_user")
                        [[ -n "$db_host" ]] && psql_args+=(-h "$db_host")
                        [[ -n "$db_port" ]] && psql_args+=(-p "$db_port")

                        PGPASSWORD="${db_pass:-}" "$psql_cmd" "${psql_args[@]}" -d postgres \
                            -c "DROP DATABASE IF EXISTS \"$ws_db\";" 2>/dev/null && \
                            success "Base de données '$ws_db' supprimée" || true
                    fi
                fi
                ;;
        esac
    fi

    # Supprimer le worktree
    cd "$root"
    git worktree remove "$wt_path" --force 2>/dev/null && \
        success "Worktree supprimé" || \
        { rm -rf "$wt_path"; success "Worktree supprimé (force)"; }

    # Supprimer la branche
    if [[ -n "$wt_branch" ]]; then
        git branch -d "$wt_branch" 2>/dev/null && \
            success "Branche '$wt_branch' supprimée" || \
            warn "Branche '$wt_branch' non supprimée (pas encore mergée ?)"
    fi

    echo ""
    success "Workspace '$sname' nettoyé."
}

# ── DESTROY (alias rapide) ──

cmd_destroy() {
    local branch_name="${1:?Usage: ws destroy <branch-name>}"
    local root
    root="$(find_project_root)"
    local sname
    sname="$(site_name "$branch_name")"
    local wt_path
    wt_path="$(worktree_path "$branch_name")"

    if [[ ! -d "$wt_path" ]]; then
        error "Workspace '$sname' introuvable."
        exit 1
    fi

    local wt_branch
    wt_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)

    echo -e "${RED}${BOLD}Suppression du workspace '$sname'${NC}"
    echo -e "  Worktree: $wt_path"
    echo -e "  Branche:  $wt_branch"
    echo ""
    read -rp "Confirmer ? (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || exit 0

    _cleanup_workspace "$sname" "$wt_path" "$wt_branch" "$root"
}

# ── HELP ──

cmd_help() {
    echo ""
    echo -e "${BOLD}ws${NC} v$VERSION — Workspace manager pour Laravel + Claude Code"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo -e "  ws create <branch> [--secure]   Crée un workspace isolé (worktree + env + db + herd)"
    echo -e "  ws run [branch]                 Lance Claude Code dans le workspace"
    echo -e "  ws status                       Affiche tous les workspaces et leur état"
    echo -e "  ws preview [branch]             Ouvre le site dans le navigateur"
    echo -e "  ws finish [branch]              Termine le travail (PR / merge / abandon)"
    echo -e "  ws destroy <branch>             Supprime le workspace, la DB, et le lien Herd"
    echo -e "  ws help                         Affiche cette aide"
    echo ""
    echo -e "${BOLD}Exemples:${NC}"
    echo -e "  ${DIM}cd ~/Users/Sites/valet/mon-projet${NC}"
    echo -e "  ws create feature/auth               ${DIM}# HTTP par défaut${NC}"
    echo -e "  ws create feature/auth --secure       ${DIM}# HTTPS avec herd secure${NC}"
    echo -e "  ws run feature/auth"
    echo -e "  ws run                                ${DIM}# depuis le worktree, ou choix interactif${NC}"
    echo -e "  ws status"
    echo -e "  ws preview feature/auth"
    echo -e "  ws finish                             ${DIM}# workflow guidé: PR, merge, ou abandon${NC}"
    echo -e "  ws destroy feature/auth"
    echo ""
    echo -e "${BOLD}Nommage:${NC}"
    echo -e "  Le site Herd utilise le format ${CYAN}projet-branche.test${NC}"
    echo -e "  Ex: projet ${DIM}mon-app${NC} + branche ${DIM}feature/login${NC} → ${CYAN}mon-app-feature-login.test${NC}"
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
            error "Commande inconnue: $command"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
