#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/config.local"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Missing configuration:"
    echo "  $CONFIG"
    echo
    echo "Run ./core/configure.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"


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
# This file intentionally remains bootstrap-managed rather than package-owned.
# Removing the core package must never remove /etc/network/interfaces.
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
# Build package
# ---------------------------------------------------------------------------
#

echo
echo "Building core package..."

PACKAGE="$("$SCRIPT_DIR/build-package.sh")"

if [[ ! -f "$PACKAGE" ]]; then
    echo "ERROR: Package build did not produce:"
    echo "  $PACKAGE"
    exit 1
fi

echo "  [OK] $PACKAGE"


#
# ---------------------------------------------------------------------------
# Install / upgrade package
# ---------------------------------------------------------------------------
#

echo
echo "Installing core package..."

apt install -y "$PACKAGE"


echo
echo "============================================================"
echo "Core installation complete."
echo "============================================================"
echo
echo "Installed package:"
dpkg-query -W -f='  ${Package} ${Version}\n' pve-setup-core
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
