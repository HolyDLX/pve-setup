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

INTERFACE_CONFIG="/etc/network/interfaces.d/05-${UPLINK_INTERFACE}"

cat > "$INTERFACE_CONFIG" <<EOF
auto $UPLINK_INTERFACE
iface $UPLINK_INTERFACE inet static
    address $HOST_ADDRESS
    gateway $HOST_GATEWAY
EOF

chmod 0644 "$INTERFACE_CONFIG"

echo
echo "Ethernet installation complete."
echo "A reboot is recommended."
