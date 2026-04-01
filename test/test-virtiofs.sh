#!/usr/bin/env bash
#
# test-virtiofs.sh — Verify virtiofs sharing works bidirectionally
#
# Run from the test/ directory after 'vagrant up' has completed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SHARED="${SCRIPT_DIR}/shared"
GUEST_SHARED="/vagrant/shared"

PASS=0
FAIL=0

# ─── Colors ─────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Helpers ────────────────────────────────────────────────────────────────────

info()  { echo -e "\n${BOLD}==> $*${RESET}"; }
pass()  { echo -e "  ${GREEN}✓${RESET} $*"; PASS=$((PASS + 1)); }
fail()  { echo -e "  ${RED}✗${RESET} $*"; FAIL=$((FAIL + 1)); }

guest_ssh() {
    cd "$SCRIPT_DIR" && vagrant ssh -c "$*" 2>/dev/null
}

local_tree() {
    (cd "$LOCAL_SHARED" && find . -not -path '.' | LC_ALL=C sort)
}

guest_tree() {
    guest_ssh "cd ${GUEST_SHARED} && find . -not -path '.' | LC_ALL=C sort" | tr -d '\r'
}

# Side-by-side diff with colors
compare_trees() {
    local label="$1"
    local local_list guest_list

    local_list=$(local_tree)
    guest_list=$(guest_tree)

    if [[ "$local_list" == "$guest_list" ]]; then
        pass "${label}"

        # Show matching tree
        local max_width=40
        local separator="│"

        printf "  ${DIM}%-${max_width}s ${separator} %-${max_width}s${RESET}\n" "Host" "Guest"
        printf "  ${DIM}%-${max_width}s ${separator} %-${max_width}s${RESET}\n" \
            "$(printf '─%.0s' $(seq 1 $max_width))" \
            "$(printf '─%.0s' $(seq 1 $max_width))"

        while IFS= read -r line; do
            printf "  ${GREEN}%-${max_width}s${RESET} ${DIM}${separator}${RESET} ${GREEN}%-${max_width}s${RESET}\n" "$line" "$line"
        done <<< "$local_list"
    else
        fail "${label}"

        local max_width=40
        local separator="│"

        printf "  ${DIM}%-${max_width}s ${separator} %-${max_width}s${RESET}\n" "Host" "Guest"
        printf "  ${DIM}%-${max_width}s ${separator} %-${max_width}s${RESET}\n" \
            "$(printf '─%.0s' $(seq 1 $max_width))" \
            "$(printf '─%.0s' $(seq 1 $max_width))"

        # Use diff to find additions/deletions
        local diff_output
        diff_output=$(diff <(echo "$local_list") <(echo "$guest_list") || true)

        # Show entries with diff markers
        local all_entries
        all_entries=$(echo -e "${local_list}\n${guest_list}" | LC_ALL=C sort -u)

        while IFS= read -r entry; do
            local in_local in_guest
            in_local=$(echo "$local_list" | grep -Fx "$entry" || true)
            in_guest=$(echo "$guest_list" | grep -Fx "$entry" || true)

            if [[ -n "$in_local" && -n "$in_guest" ]]; then
                printf "  %-${max_width}s ${DIM}${separator}${RESET} %-${max_width}s\n" "$entry" "$entry"
            elif [[ -n "$in_local" && -z "$in_guest" ]]; then
                printf "  ${GREEN}%-${max_width}s${RESET} ${DIM}${separator}${RESET} ${RED}%-${max_width}s${RESET}\n" "$entry" "(missing)"
            else
                printf "  ${RED}%-${max_width}s${RESET} ${DIM}${separator}${RESET} ${GREEN}%-${max_width}s${RESET}\n" "(missing)" "$entry"
            fi
        done <<< "$all_entries"
    fi
}

# ─── Preflight ──────────────────────────────────────────────────────────────────

# Clean up and create fresh test directory
rm -rf "${LOCAL_SHARED}"
mkdir -p "${LOCAL_SHARED}/src" "${LOCAL_SHARED}/config" "${LOCAL_SHARED}/data/logs" "${LOCAL_SHARED}/data/cache"
echo 'puts "Hello from RPi!"' > "${LOCAL_SHARED}/src/main.rb"
echo 'console.log("test")' > "${LOCAL_SHARED}/src/app.js"
printf "host: localhost\nport: 8080\n" > "${LOCAL_SHARED}/config/settings.yml"
echo "$(date) build test" > "${LOCAL_SHARED}/data/logs/build.log"
echo "cached" > "${LOCAL_SHARED}/data/cache/temp.dat"
printf "# Test Project\nShared filesystem test\n" > "${LOCAL_SHARED}/README.md"

info "Checking prerequisites..."

if ! (cd "$SCRIPT_DIR" && vagrant status --machine-readable 2>/dev/null | grep -q "state,running"); then
    echo "ERROR: VM is not running. Run 'vagrant up' first."
    exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════════
# TEST 1: Existing files visible in both directions
# ═════════════════════════════════════════════════════════════════════════════════

info "TEST 1: Existing files visible inside guest"
compare_trees "Existing files match"

# ═════════════════════════════════════════════════════════════════════════════════
# TEST 2: Files created locally appear inside guest
# ═════════════════════════════════════════════════════════════════════════════════

info "TEST 2: Create files locally, verify inside guest"

mkdir -p "${LOCAL_SHARED}/local-created/nested"
echo "created on host at $(date)" > "${LOCAL_SHARED}/local-created/from-host.txt"
echo "nested file" > "${LOCAL_SHARED}/local-created/nested/deep.txt"

if guest_ssh "cat ${GUEST_SHARED}/local-created/from-host.txt" | grep -q "created on host"; then
    pass "File created locally is readable in guest"
else
    fail "File created locally not found in guest"
fi

if guest_ssh "test -f ${GUEST_SHARED}/local-created/nested/deep.txt && echo ok" | grep -q "ok"; then
    pass "Nested file created locally is visible in guest"
else
    fail "Nested file created locally not visible in guest"
fi

compare_trees "After local file creation"

# ═════════════════════════════════════════════════════════════════════════════════
# TEST 3: Files created inside guest appear locally
# ═════════════════════════════════════════════════════════════════════════════════

info "TEST 3: Create files inside guest, verify locally"

guest_ssh "mkdir -p ${GUEST_SHARED}/guest-created/nested"
guest_ssh "sh -c 'echo \"created in guest at \$(date)\" > ${GUEST_SHARED}/guest-created/from-guest.txt'"
guest_ssh "sh -c 'echo \"nested guest file\" > ${GUEST_SHARED}/guest-created/nested/deep.txt'"

if [[ -f "${LOCAL_SHARED}/guest-created/from-guest.txt" ]] && grep -q "created in guest" "${LOCAL_SHARED}/guest-created/from-guest.txt"; then
    pass "File created in guest is readable locally"
else
    fail "File created in guest not found locally"
fi

if [[ -f "${LOCAL_SHARED}/guest-created/nested/deep.txt" ]]; then
    pass "Nested file created in guest is visible locally"
else
    fail "Nested file created in guest not visible locally"
fi

compare_trees "After guest file creation"

# ═════════════════════════════════════════════════════════════════════════════════
# TEST 4: Modifications propagate both ways
# ═════════════════════════════════════════════════════════════════════════════════

info "TEST 4: Modifications propagate bidirectionally"

echo "appended locally" >> "${LOCAL_SHARED}/local-created/from-host.txt"
if guest_ssh "cat ${GUEST_SHARED}/local-created/from-host.txt" | grep -q "appended locally"; then
    pass "Local modification visible in guest"
else
    fail "Local modification not visible in guest"
fi

guest_ssh "sh -c 'echo \"appended in guest\" >> ${GUEST_SHARED}/guest-created/from-guest.txt'"
if grep -q "appended in guest" "${LOCAL_SHARED}/guest-created/from-guest.txt"; then
    pass "Guest modification visible locally"
else
    fail "Guest modification not visible locally"
fi

# ═════════════════════════════════════════════════════════════════════════════════
# TEST 5: Deletion propagates both ways
# ═════════════════════════════════════════════════════════════════════════════════

info "TEST 5: Deletion propagates bidirectionally"

rm "${LOCAL_SHARED}/local-created/nested/deep.txt"
if guest_ssh "test ! -f ${GUEST_SHARED}/local-created/nested/deep.txt && echo ok" | grep -q "ok"; then
    pass "Local deletion visible in guest"
else
    fail "Local deletion not visible in guest"
fi

guest_ssh "rm ${GUEST_SHARED}/guest-created/nested/deep.txt"
if [[ ! -f "${LOCAL_SHARED}/guest-created/nested/deep.txt" ]]; then
    pass "Guest deletion visible locally"
else
    fail "Guest deletion not visible locally"
fi

# ═════════════════════════════════════════════════════════════════════════════════
# TEST 6: UID/GID mapping — pi user owns files, can read/write without sudo
# ═════════════════════════════════════════════════════════════════════════════════

info "TEST 6: UID/GID mapping"

HOST_USER=$(whoami)
GUEST_OWNER=$(guest_ssh "stat -c '%U' ${GUEST_SHARED}/README.md" | tr -d '[:space:]')

if [[ "$GUEST_OWNER" == "pi" ]]; then
    pass "Host files appear owned by vagrant inside guest"
else
    fail "Host files owned by '${GUEST_OWNER}' instead of 'pi'"
fi

# pi can write without sudo
guest_ssh "sh -c 'echo uid-test > ${GUEST_SHARED}/uid-test.txt'"
if [[ -f "${LOCAL_SHARED}/uid-test.txt" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        HOST_OWNER=$(stat -f '%Su' "${LOCAL_SHARED}/uid-test.txt")
    else
        HOST_OWNER=$(stat -c '%U' "${LOCAL_SHARED}/uid-test.txt")
    fi
    if [[ "$HOST_OWNER" == "$HOST_USER" ]]; then
        pass "Guest vagrant writes appear as ${HOST_USER} on host"
    else
        fail "Guest vagrant writes owned by '${HOST_OWNER}' instead of '${HOST_USER}'"
    fi
else
    fail "Guest vagrant could not write to shared folder"
fi

# Host-created files are writable by pi
echo "host-written" > "${LOCAL_SHARED}/host-owned.txt"
if guest_ssh "sh -c 'echo pi-appended >> ${GUEST_SHARED}/host-owned.txt' && echo ok" | grep -q "ok"; then
    pass "vagrant can modify host-created files"
else
    fail "vagrant cannot modify host-created files"
fi

rm -f "${LOCAL_SHARED}/uid-test.txt" "${LOCAL_SHARED}/host-owned.txt"

# ═════════════════════════════════════════════════════════════════════════════════
# Cleanup test artifacts
# ═════════════════════════════════════════════════════════════════════════════════

info "Cleaning up test artifacts..."
rm -rf "${LOCAL_SHARED}"

# ═════════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}════════════════════════════════════${RESET}"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Results: ${PASS} passed, ${FAIL} failed${RESET}"
else
    echo -e "  ${RED}${BOLD}Results: ${PASS} passed, ${FAIL} failed${RESET}"
fi
echo -e "${BOLD}════════════════════════════════════${RESET}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
