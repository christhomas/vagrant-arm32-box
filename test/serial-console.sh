#!/usr/bin/env bash
# Connect to the QEMU serial console for the test VM.
# Run this in a separate terminal while vagrant up is running.
# Press Ctrl-C to disconnect.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID_FILE="${SCRIPT_DIR}/.vagrant/machines/default/qemu/id"

if [[ ! -f "$ID_FILE" ]]; then
    echo "No VM found. Run 'vagrant up' first."
    exit 1
fi

VM_ID=$(cat "$ID_FILE")
SOCKET="${HOME}/.vagrant.d/tmp/vagrant-qemu/${VM_ID}/qemu_socket_serial"

if [[ ! -S "$SOCKET" ]]; then
    echo "Serial socket not found: ${SOCKET}"
    exit 1
fi

echo "Connecting to serial console (Ctrl-C to disconnect)..."
socat - "UNIX-CONNECT:${SOCKET}"
