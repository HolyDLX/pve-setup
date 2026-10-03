#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/config.local"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Missing configuration:"
    echo "  $CONFIG"
    echo
    echo "Run ./core/configure.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"


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
echo "Installing core Proxmox configuration..."
echo
echo "  Uplink:     $UPLINK_INTERFACE"
echo "  Host:       $HOST_ADDRESS"
echo "  Gateway:    $HOST_GATEWAY"
echo "  VM bridge:  $VM_BRIDGE"
echo "  VM network: $VM_NETWORK"
echo "  VM gateway: $VM_GATEWAY"


#
# ---------------------------------------------------------------------------
# Main interfaces file
# ---------------------------------------------------------------------------
#
# A fresh Proxmox installation normally places the management IP on vmbr0.
#
# This setup intentionally does NOT use vmbr0 as the physical LAN bridge:
#
#   Wi-Fi interface -> physical LAN / management
#   vmbr0           -> private VM/LXC network
#
# Therefore the installer-generated vmbr0 configuration must be removed.
#
# All managed interfaces are placed in /etc/network/interfaces.d/.
#

echo
echo "Configuring /etc/network/interfaces..."

INTERFACES_FILE="/etc/network/interfaces"
BACKUP_FILE="/etc/network/interfaces.pre-pve-setup"

if [[ -f "$INTERFACES_FILE" && ! -f "$BACKUP_FILE" ]]; then
    cp "$INTERFACES_FILE" "$BACKUP_FILE"

    echo "  [OK] Original configuration backed up to:"
    echo "       $BACKUP_FILE"
fi

cat > "$INTERFACES_FILE" <<'EOF'
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
EOF

echo "  [OK] Removed installer-generated bridge configuration"


#
# ---------------------------------------------------------------------------
# Private VM bridge
# ---------------------------------------------------------------------------
#

echo
echo "Installing private VM bridge..."

mkdir -p /etc/network/interfaces.d

BRIDGE_CONFIG="/etc/network/interfaces.d/10-${VM_BRIDGE}"

render \
    "$TEMPLATE_DIR/10-vmbr0.template" \
    "$BRIDGE_CONFIG"

chmod 0644 "$BRIDGE_CONFIG"

echo "  [OK] $BRIDGE_CONFIG"


#
# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
#

echo
echo "Installing tty1 dashboard..."

DASHBOARD="/usr/local/sbin/pve-dashboard"

render \
    "$TEMPLATE_DIR/pve-dashboard.template" \
    "$DASHBOARD"

chmod 0755 "$DASHBOARD"

echo "  [OK] $DASHBOARD"


#
# ---------------------------------------------------------------------------
# tty1 systemd override
# ---------------------------------------------------------------------------
#

echo
echo "Configuring tty1..."

TTY_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
TTY_OVERRIDE="$TTY_OVERRIDE_DIR/override.conf"

mkdir -p "$TTY_OVERRIDE_DIR"

cp \
    "$TEMPLATE_DIR/getty-tty1-override.conf" \
    "$TTY_OVERRIDE"

chmod 0644 "$TTY_OVERRIDE"

echo "  [OK] tty1 dashboard override installed"


#
# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
#

echo
echo "Reloading systemd..."

systemctl daemon-reload
systemctl enable getty@tty1.service >/dev/null

echo "  [OK] tty1 dashboard enabled"


#
# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
#

echo
echo "Configuration files:"
echo

echo "----- /etc/network/interfaces -----"
cat /etc/network/interfaces

echo
echo "----- Wi-Fi uplink -----"

UPLINK_CONFIG="/etc/network/interfaces.d/05-${UPLINK_INTERFACE}"

if [[ -f "$UPLINK_CONFIG" ]]; then
    cat "$UPLINK_CONFIG"
else
    echo "WARNING: $UPLINK_CONFIG does not exist."
fi

echo
echo "----- VM bridge -----"
cat "$BRIDGE_CONFIG"


echo
echo "============================================================"
echo "Core installation complete."
echo "============================================================"
echo
echo "Expected network layout after reboot:"
echo
echo "  $UPLINK_INTERFACE"
echo "      $HOST_ADDRESS"
echo "      gateway $HOST_GATEWAY"
echo
echo "  $VM_BRIDGE"
echo "      $VM_GATEWAY"
echo "      private network $VM_NETWORK"
echo
echo "The LAN address must NOT also appear on $VM_BRIDGE."
echo
echo "Reboot to apply the clean network configuration:"
echo
echo "  reboot"
echo