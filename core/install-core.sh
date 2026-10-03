#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/config.local"

if [[ ! -f "$CONFIG" ]]; then
    echo "Missing configuration:"
    echo "  $CONFIG"
    echo
    echo "Run ./core/configure.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

render() {
    local src="$1"
    local dst="$2"
    local mode="$3"

    mkdir -p "$(dirname "$dst")"

    sed \
        -e "s|{{UPLINK_INTERFACE}}|${UPLINK_INTERFACE}|g" \
        -e "s|{{VM_BRIDGE}}|${VM_BRIDGE}|g" \
        -e "s|{{VM_NETWORK}}|${VM_NETWORK}|g" \
        -e "s|{{VM_GATEWAY}}|${VM_GATEWAY}|g" \
        "$src" > "$dst"

    chmod "$mode" "$dst"
}

echo "Installing core Proxmox configuration..."

render \
    "$SCRIPT_DIR/templates/10-vmbr0.template" \
    "/etc/network/interfaces.d/10-${VM_BRIDGE}" \
    0644

render \
    "$SCRIPT_DIR/templates/pve-dashboard.template" \
    /usr/local/sbin/pve-dashboard \
    0755

install -D -m 0644 \
    "$SCRIPT_DIR/templates/getty-tty1-override.conf" \
    /etc/systemd/system/getty@tty1.service.d/override.conf

systemctl daemon-reload
systemctl enable getty@tty1.service

echo
echo "Core installation complete."
