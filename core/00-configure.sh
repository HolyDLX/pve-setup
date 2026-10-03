#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$REPO_ROOT/config.local"

echo "Available interfaces:"
ip -br link
echo

read -r -p "Uplink interface: " UPLINK_INTERFACE
read -r -p "Host address with prefix: " HOST_ADDRESS
read -r -p "Host gateway: " HOST_GATEWAY

read -r -p "VM bridge [vmbr0]: " VM_BRIDGE
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"

read -r -p "VM network [10.10.10.0/24]: " VM_NETWORK
VM_NETWORK="${VM_NETWORK:-10.10.10.0/24}"

read -r -p "VM gateway [10.10.10.1]: " VM_GATEWAY
VM_GATEWAY="${VM_GATEWAY:-10.10.10.1}"

cat > "$CONFIG" <<EOF
UPLINK_INTERFACE="$UPLINK_INTERFACE"
HOST_ADDRESS="$HOST_ADDRESS"
HOST_GATEWAY="$HOST_GATEWAY"

VM_BRIDGE="$VM_BRIDGE"
VM_NETWORK="$VM_NETWORK"
VM_GATEWAY="$VM_GATEWAY"
EOF

chmod 600 "$CONFIG"

echo
echo "Configuration written to:"
echo "  $CONFIG"
