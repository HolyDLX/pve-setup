#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CORE_CONFIG="$REPO_ROOT/config.local"
PAPERLESS_CONFIG="$SCRIPT_DIR/config.local"

if [[ ! -f "$CORE_CONFIG" ]]; then
    echo "Missing core configuration:"
    echo "  $CORE_CONFIG"
    echo
    echo "Run the core installer first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CORE_CONFIG"

DEFAULT_CTID=100
DEFAULT_IP="10.10.10.10"
DEFAULT_PORT=8000
DEFAULT_HOSTNAME="paperless"

read -r -p "Container ID [$DEFAULT_CTID]: " PAPERLESS_CTID
PAPERLESS_CTID="${PAPERLESS_CTID:-$DEFAULT_CTID}"

read -r -p "Container IP [$DEFAULT_IP]: " PAPERLESS_IP
PAPERLESS_IP="${PAPERLESS_IP:-$DEFAULT_IP}"

read -r -p "Paperless port [$DEFAULT_PORT]: " PAPERLESS_PORT
PAPERLESS_PORT="${PAPERLESS_PORT:-$DEFAULT_PORT}"

read -r -p "Container hostname [$DEFAULT_HOSTNAME]: " PAPERLESS_HOSTNAME
PAPERLESS_HOSTNAME="${PAPERLESS_HOSTNAME:-$DEFAULT_HOSTNAME}"

cat > "$PAPERLESS_CONFIG" <<EOF
PAPERLESS_CTID="$PAPERLESS_CTID"
PAPERLESS_IP="$PAPERLESS_IP"
PAPERLESS_PORT="$PAPERLESS_PORT"
PAPERLESS_HOSTNAME="$PAPERLESS_HOSTNAME"
EOF

chmod 600 "$PAPERLESS_CONFIG"

echo
echo "Creating and installing Paperless LXC..."

"$SCRIPT_DIR/install-lxc.sh"

echo
echo "Installing host-side network forwarding..."

render() {
    local src="$1"
    local dst="$2"

    sed \
        -e "s|{{UPLINK_INTERFACE}}|${UPLINK_INTERFACE}|g" \
        -e "s|{{PAPERLESS_IP}}|${PAPERLESS_IP}|g" \
        -e "s|{{PAPERLESS_PORT}}|${PAPERLESS_PORT}|g" \
        "$src" > "$dst"

    chmod 0755 "$dst"
}

render \
    "$SCRIPT_DIR/templates/network-paperless-up.template" \
    /etc/network/if-up.d/network-paperless

render \
    "$SCRIPT_DIR/templates/network-paperless-down.template" \
    /etc/network/if-down.d/network-paperless

echo
echo "Paperless installation complete."
echo
echo "Container:"
echo "  CT ID:     $PAPERLESS_CTID"
echo "  IP:        $PAPERLESS_IP"
echo
echo "Forward:"
echo "  ${UPLINK_INTERFACE}:${PAPERLESS_PORT} -> ${PAPERLESS_IP}:${PAPERLESS_PORT}"
