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

echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
