#!/usr/bin/env bash
#
# build-box.sh — Build a Vagrant box from Raspberry Pi OS armhf lite
#
# On Linux: runs build-linux.sh directly (for CI or native Linux)
# On macOS: boots a build VM via Vagrant and runs build-linux.sh inside it
#
# Usage:
#   ./build-box.sh [--skip-register]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX_NAME="christhomas/vagrant-arm32-box"
BOX_FILE="$SCRIPT_DIR/debian-arm32.box"

# ─── Argument parsing ───────────────────────────────────────────────────────────

SKIP_REGISTER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-register)  SKIP_REGISTER=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--skip-register]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
die()   { echo "FATAL: $*" >&2; exit 1; }

# ═════════════════════════════════════════════════════════════════════════════════
# Build
# ═════════════════════════════════════════════════════════════════════════════════

OS="$(uname -s)"

if [[ "$OS" == "Linux" ]]; then
    info "Running build directly on Linux..."
    sudo "${SCRIPT_DIR}/build-linux.sh"
else
    info "Running build inside Vagrant build VM..."

    buildvm() {
        VAGRANT_VAGRANTFILE="${SCRIPT_DIR}/Vagrantfile" \
        VAGRANT_DOTFILE_PATH="${SCRIPT_DIR}/.vagrant" \
        vagrant "$@"
    }

    buildvm up --provider=qemu
    buildvm ssh -- -t "sudo BUILD_PROJECT=/build-project /build-project/build-linux.sh"
fi

# ═════════════════════════════════════════════════════════════════════════════════
# Register
# ═════════════════════════════════════════════════════════════════════════════════

[[ -f "$SCRIPT_DIR/work/debian-arm32.box" ]] || die "Box file not found — build failed"
mv "$SCRIPT_DIR/work/debian-arm32.box" "$BOX_FILE"

BOX_SIZE=$(du -h "$BOX_FILE" | cut -f1)
info "Box created: $BOX_FILE ($BOX_SIZE)"

if [[ "$SKIP_REGISTER" == "false" ]]; then
    echo ""
    read -rp "Add box as '$BOX_NAME' to Vagrant? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        vagrant box remove "$BOX_NAME" --force 2>/dev/null || true
        vagrant box add --name "$BOX_NAME" --architecture arm "$BOX_FILE"
        info "Box '$BOX_NAME' registered."
    else
        info "Skipped. Add manually:"
        echo "  vagrant box add --name '$BOX_NAME' --architecture arm '$BOX_FILE'"
    fi
else
    info "Skipping registration."
fi

echo ""
info "Done!"
echo "  Box:  $BOX_FILE"
echo "  Name: $BOX_NAME"
