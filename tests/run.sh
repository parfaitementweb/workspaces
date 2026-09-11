#!/usr/bin/env bash
# Unit checks for ws helpers. Usage: bash tests/run.sh [path/to/ws]
set -euo pipefail

WS_BIN="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ws}"
# shellcheck source=../ws
source "$WS_BIN"

PASSED=0 FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "    $label: expected [$expected], got [$actual]"
        return 1
    fi
}

# Count how many entries a `while read` consumer sees, and keep the last one
count_subdomains() {
    local root="$1" prefix env_var
    SUBDOMAIN_COUNT=0 SUBDOMAIN_LAST=""
    while IFS=: read -r prefix env_var; do
        SUBDOMAIN_COUNT=$((SUBDOMAIN_COUNT + 1))
        SUBDOMAIN_LAST="${prefix}:${env_var}"
    done < <(_ws_config_subdomains "$root")
}

make_root() {
    local root="$TMP/$1"
    mkdir -p "$root"
    [[ $# -gt 1 ]] && printf '%s\n' "$2" > "$root/.ws.json"
    echo "$root"
}

case_single_subdomain_read_loop() {
    local root
    root="$(make_root single '{"subdomains": {"cp": "FILAMENT_DOMAIN"}}')"
    count_subdomains "$root"
    assert_eq 1 "$SUBDOMAIN_COUNT" "iterations (cold cache)"
    assert_eq "cp:FILAMENT_DOMAIN" "$SUBDOMAIN_LAST" "entry (cold cache)"
    count_subdomains "$root"
    assert_eq 1 "$SUBDOMAIN_COUNT" "iterations (warm cache)"
    assert_eq "cp:FILAMENT_DOMAIN" "$SUBDOMAIN_LAST" "entry (warm cache)"
}

case_single_subdomain_ends_with_newline() {
    local root
    root="$(make_root newline '{"subdomains": {"cp": "FILAMENT_DOMAIN"}}')"
    _ws_config_subdomains "$root" > "$TMP/newline.out"
    assert_eq "cp:FILAMENT_DOMAIN" "$(cat "$TMP/newline.out")" "content"
    assert_eq 19 "$(wc -c < "$TMP/newline.out" | tr -d ' ')" "byte count (with trailing newline)"
}

case_two_subdomains_read_loop() {
    local root
    root="$(make_root two '{"subdomains": {"cp": "FILAMENT_DOMAIN", "api": "API_DOMAIN"}}')"
    count_subdomains "$root"
    assert_eq 2 "$SUBDOMAIN_COUNT" "iterations"
    assert_eq "api:API_DOMAIN" "$SUBDOMAIN_LAST" "last entry"
}

case_has_subdomains() {
    local with without missing
    with="$(make_root has-with '{"subdomains": {"cp": "FILAMENT_DOMAIN"}}')"
    without="$(make_root has-without '{"domain": "APP_DOMAIN"}')"
    missing="$(make_root has-missing)"
    if ! _ws_config_has_subdomains "$with"; then
        echo "    single subdomain: expected true"; return 1
    fi
    if _ws_config_has_subdomains "$without"; then
        echo "    no subdomains key: expected false"; return 1
    fi
    if _ws_config_has_subdomains "$missing"; then
        echo "    no .ws.json: expected false"; return 1
    fi
}

case_no_subdomains_emits_nothing() {
    local root
    root="$(make_root empty '{"domain": "APP_DOMAIN"}')"
    _ws_config_subdomains "$root" > "$TMP/empty.out"
    assert_eq 0 "$(wc -c < "$TMP/empty.out" | tr -d ' ')" "byte count"
    count_subdomains "$root"
    assert_eq 0 "$SUBDOMAIN_COUNT" "iterations"
}

case_setup_env_single_subdomain() {
    local root wt
    root="$(make_root env-root '{"subdomains": {"cp": "FILAMENT_DOMAIN"}}')"
    cat > "$root/.env" <<'ENV'
APP_URL=https://bankhouse.test
SESSION_DOMAIN=bankhouse.test
FILAMENT_DOMAIN=cpw.bankhouse.test
ENV
    echo '{"require": {"laravel/sanctum": "^4.0"}}' > "$root/composer.json"
    wt="$TMP/env-wt"
    mkdir -p "$wt"
    cp "$root/composer.json" "$wt/"
    (cd "$wt" && _setup_env "$root" "bankhouse-feat-x" > /dev/null 2>&1)
    assert_eq "cp.bankhouse-feat-x.test" "$(_get_env_var "$wt/.env" FILAMENT_DOMAIN)" "FILAMENT_DOMAIN"
    assert_eq ".bankhouse-feat-x.test" "$(_get_env_var "$wt/.env" SESSION_DOMAIN)" "SESSION_DOMAIN"
    assert_eq "bankhouse-feat-x.test,cp.bankhouse-feat-x.test" "$(_get_env_var "$wt/.env" SANCTUM_STATEFUL_DOMAINS)" "SANCTUM_STATEFUL_DOMAINS"
}

case_setup_agent_files_copies_configs() {
    local root wt f
    root="$(make_root agent-copy-root)"
    wt="$TMP/agent-copy-wt"
    mkdir -p "$root/.claude" "$root/.codex" "$wt"
    echo '{"permissions": {"allow": []}}' > "$root/.claude/settings.local.json"
    echo 'Local agent instructions' > "$root/CLAUDE.local.md"
    printf '%s\n' '[mcp_servers.db-prod]' 'command = "example-mcp"' > "$root/.codex/config.toml"
    (cd "$wt" && _setup_agent_files "$root" > /dev/null) || return 1
    for f in .claude/settings.local.json CLAUDE.local.md .codex/config.toml; do
        cmp "$root/$f" "$wt/$f" || return 1
    done
}

case_setup_agent_files_without_source() {
    local root wt
    root="$(make_root agent-missing-root)"
    wt="$TMP/agent-missing-wt"
    mkdir -p "$wt"
    (cd "$wt" && _setup_agent_files "$root" > /dev/null) || return 1
    if [[ -e "$wt/.codex" || -e "$wt/.claude" || -e "$wt/CLAUDE.local.md" ]]; then
        echo "    absent sources: expected no agent files or parent directories"
        return 1
    fi
}

case_setup_agent_files_preserves_existing_config() {
    local root wt
    root="$(make_root agent-existing-root)"
    wt="$TMP/agent-existing-wt"
    mkdir -p "$root/.codex" "$wt/.codex"
    printf '%s\n' '[mcp_servers.db-prod]' 'command = "main-mcp"' > "$root/.codex/config.toml"
    printf '%s\n' '[mcp_servers.db-local]' 'command = "workspace-mcp"' > "$TMP/agent-existing-expected.toml"
    cp "$TMP/agent-existing-expected.toml" "$wt/.codex/config.toml"
    (cd "$wt" && _setup_agent_files "$root" > /dev/null) || return 1
    cmp "$TMP/agent-existing-expected.toml" "$wt/.codex/config.toml"
}

# Fake project: git repo with a main branch, .ws.json and one worktree under .worktrees/
make_project() {
    local name="$1" config="$2" sname="$3" root
    root="$TMP/$name"
    mkdir -p "$root"
    git -C "$root" init -q
    git -C "$root" symbolic-ref HEAD refs/heads/main
    git -C "$root" -c user.name=ws -c user.email=ws@test commit -q --allow-empty -m init
    printf '%s\n' "$config" > "$root/.ws.json"
    git -C "$root" worktree add -q "$root/.worktrees/$sname" -b "feat-$name" 2>/dev/null
    echo "$root"
}

status_json() {
    (cd "$1" && WS_JSON="" bash "$WS_BIN" status --json 2>/dev/null)
}

urls_member() {
    sed -n 's/.*\("urls":\[[^]]*\]\).*/\1/p'
}

case_workspace_urls_reads_env_hosts() {
    local root dir
    root="$(make_root urls-env '{"domain": "APP_DOMAIN", "subdomains": {"cp": "FILAMENT_DOMAIN", "api": "API_DOMAIN"}}')"
    dir="$TMP/urls-env-wt"
    mkdir -p "$dir"
    cat > "$dir/.env" <<'ENV'
APP_URL=https://bankhouse-feat-x.test
APP_DOMAIN=bankhouse-feat-x.test
FILAMENT_DOMAIN=cp.bankhouse-feat-x.test
API_DOMAIN="api.bankhouse-feat-x.test"
ENV
    WR_PROFILE="$PROFILE_LARAVEL"
    assert_eq "$(printf '|https://bankhouse-feat-x.test\ncp|https://cp.bankhouse-feat-x.test\napi|https://api.bankhouse-feat-x.test')" \
        "$(_workspace_urls "$root" "$dir" "bankhouse-feat-x")" "lines"
}

case_workspace_urls_falls_back_without_env_var() {
    local root dir
    root="$(make_root urls-fallback '{"subdomains": {"cp": "FILAMENT_DOMAIN"}}')"
    dir="$TMP/urls-fallback-wt"
    mkdir -p "$dir"
    echo 'APP_URL=http://bankhouse-feat-x.test' > "$dir/.env"
    WR_PROFILE="$PROFILE_LARAVEL"
    assert_eq "$(printf '|http://bankhouse-feat-x.test\ncp|http://cp.bankhouse-feat-x.test')" \
        "$(_workspace_urls "$root" "$dir" "bankhouse-feat-x")" "lines"
}

case_workspace_urls_plain_emits_nothing() {
    local root dir
    root="$(make_root urls-plain '{"subdomains": {"cp": "FILAMENT_DOMAIN"}}')"
    dir="$TMP/urls-plain-wt"
    mkdir -p "$dir"
    echo 'APP_URL=http://bankhouse-feat-x.test' > "$dir/.env"
    WR_PROFILE="$PROFILE_PLAIN"
    assert_eq "" "$(_workspace_urls "$root" "$dir" "bankhouse-feat-x")" "output"
}

case_status_json_urls_with_env_var() {
    local root sname="ws-test-json-env" out
    root="$(make_project json-env '{"profile": "laravel-herd", "domain": "APP_DOMAIN", "subdomains": {"cp": "FILAMENT_DOMAIN"}}' "$sname")"
    cat > "$root/.worktrees/$sname/.env" <<ENV
APP_URL=http://$sname.test
APP_DOMAIN=$sname.test
FILAMENT_DOMAIN=cp.$sname.test
ENV
    out="$(status_json "$root")"
    assert_eq "\"urls\":[{\"url\":\"http://$sname.test\"},{\"name\":\"cp\",\"url\":\"http://cp.$sname.test\"}]" \
        "$(printf '%s' "$out" | urls_member)" "urls member"
    assert_eq 1 "$(printf '%s' "$out" | grep -c "\"url\":\"http://$sname.test\",\"urls\"")" "url kept before urls"
}

case_status_json_urls_without_env_var() {
    local root sname="ws-test-json-fallback" out
    root="$(make_project json-fallback '{"profile": "laravel-herd", "subdomains": {"cp": "FILAMENT_DOMAIN", "api": "API_DOMAIN"}}' "$sname")"
    echo "APP_URL=http://$sname.test" > "$root/.worktrees/$sname/.env"
    out="$(status_json "$root")"
    assert_eq "\"urls\":[{\"url\":\"http://$sname.test\"},{\"name\":\"cp\",\"url\":\"http://cp.$sname.test\"},{\"name\":\"api\",\"url\":\"http://api.$sname.test\"}]" \
        "$(printf '%s' "$out" | urls_member)" "urls member"
}

case_status_json_plain_has_no_urls() {
    local root sname="ws-test-json-plain" out
    root="$(make_project json-plain '{"profile": "plain", "subdomains": {"cp": "FILAMENT_DOMAIN"}}' "$sname")"
    echo "APP_URL=http://$sname.test" > "$root/.worktrees/$sname/.env"
    out="$(status_json "$root")"
    assert_eq 1 "$(printf '%s' "$out" | grep -c '"profile":"plain"')" "plain record"
    assert_eq 0 "$(printf '%s' "$out" | grep -c '"url')" "no url or urls"
}

run_case() {
    local name="$1" rc
    set +e
    ( "$name" )
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        PASSED=$((PASSED + 1)); echo "  ok   $name"
    else
        FAILED=$((FAILED + 1)); echo "  FAIL $name"
    fi
}

echo "ws tests ($WS_BIN)"
run_case case_single_subdomain_read_loop
run_case case_single_subdomain_ends_with_newline
run_case case_two_subdomains_read_loop
run_case case_has_subdomains
run_case case_no_subdomains_emits_nothing
run_case case_setup_env_single_subdomain
run_case case_setup_agent_files_copies_configs
run_case case_setup_agent_files_without_source
run_case case_setup_agent_files_preserves_existing_config
run_case case_workspace_urls_reads_env_hosts
run_case case_workspace_urls_falls_back_without_env_var
run_case case_workspace_urls_plain_emits_nothing
run_case case_status_json_urls_with_env_var
run_case case_status_json_urls_without_env_var
run_case case_status_json_plain_has_no_urls

echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
