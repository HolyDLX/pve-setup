#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST_CONFIG="$REPO_ROOT/config.local"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

if [[ ! -f "$HOST_CONFIG" ]]; then
    echo "ERROR: Missing host configuration:"
    echo "  $HOST_CONFIG"
    exit 1
fi

# shellcheck source=/dev/null
source "$HOST_CONFIG"


render() {
    local source="$1"
    local destination="$2"

    sed \
        -e "s|{{UPLINK_INTERFACE}}|$UPLINK_INTERFACE|g" \
        -e "s|{{VM_BRIDGE}}|$VM_BRIDGE|g" \
        -e "s|{{VM_NETWORK}}|$VM_NETWORK|g" \
        -e "s|{{VM_GATEWAY}}|$VM_GATEWAY|g" \
        "$source" > "$destination"
}


echo
echo "Updating core templates..."
echo


#
# ---------------------------------------------------------------------------
# VM bridge template
# ---------------------------------------------------------------------------
#

BRIDGE_CONFIG="/etc/network/interfaces.d/10-${VM_BRIDGE}"

if [[ -f "$TEMPLATE_DIR/10-vmbr0.template" ]]; then
    echo "Updating VM bridge configuration..."

    render \
        "$TEMPLATE_DIR/10-vmbr0.template" \
        "$BRIDGE_CONFIG"

    chmod 0644 "$BRIDGE_CONFIG"

    echo "  [OK] $BRIDGE_CONFIG"
fi


#
# ---------------------------------------------------------------------------
# Dashboard template
# ---------------------------------------------------------------------------
#

DASHBOARD="/usr/local/sbin/pve-dashboard"

if [[ -f "$TEMPLATE_DIR/pve-dashboard.template" ]]; then
    echo "Updating tty1 dashboard..."

    render \
        "$TEMPLATE_DIR/pve-dashboard.template" \
        "$DASHBOARD"

    chmod 0755 "$DASHBOARD"

    echo "  [OK] $DASHBOARD"
fi


#
# ---------------------------------------------------------------------------
# tty1 systemd override
# ---------------------------------------------------------------------------
#

TTY_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
TTY_OVERRIDE="$TTY_OVERRIDE_DIR/override.conf"

if [[ -f "$TEMPLATE_DIR/getty-tty1-override.conf" ]]; then
    echo "Updating tty1 service override..."

    mkdir -p "$TTY_OVERRIDE_DIR"

    cp \
        "$TEMPLATE_DIR/getty-tty1-override.conf" \
        "$TTY_OVERRIDE"

    chmod 0644 "$TTY_OVERRIDE"

    echo "  [OK] $TTY_OVERRIDE"
fi


#
# ---------------------------------------------------------------------------
# Reload services
# ---------------------------------------------------------------------------
#

echo
echo "Reloading systemd..."

systemctl daemon-reload

echo "Restarting tty1 dashboard..."

systemctl restart getty@tty1.service

echo
echo "============================================================"
echo "Core templates updated."
echo "============================================================"