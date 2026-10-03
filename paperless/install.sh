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

if [[ -f "$PAPERLESS_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$PAPERLESS_CONFIG"

    DEFAULT_CTID="${PAPERLESS_CTID:-$DEFAULT_CTID}"
    DEFAULT_IP="${PAPERLESS_IP:-$DEFAULT_IP}"
    DEFAULT_PORT="${PAPERLESS_PORT:-$DEFAULT_PORT}"
    DEFAULT_HOSTNAME="${PAPERLESS_HOSTNAME:-$DEFAULT_HOSTNAME}"
fi

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


#
# ---------------------------------------------------------------------------
# Guest installation
# ---------------------------------------------------------------------------
#
# The guest is provisioned only once. Re-running this script rebuilds and
# upgrades the host-side package without recreating an existing LXC.
#

if pct status "$PAPERLESS_CTID" &>/dev/null; then
    echo
    echo "Container $PAPERLESS_CTID already exists."
    echo "Skipping guest installation."
else
    echo
    echo "Creating and installing Paperless LXC..."

    "$SCRIPT_DIR/install-lxc.sh"
fi


#
# ---------------------------------------------------------------------------
# Build package
# ---------------------------------------------------------------------------
#

echo
echo "Building Paperless host package..."

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
echo "Installing Paperless host package..."

apt install -y "$PACKAGE"


echo
echo "============================================================"
echo "Paperless installation complete."
echo "============================================================"
echo
echo "Installed package:"
dpkg-query -W -f='  ${Package} ${Version}\n' pve-setup-paperless
echo
echo "Container:"
echo "  CT ID:     $PAPERLESS_CTID"
echo "  IP:        $PAPERLESS_IP"
echo
echo "Forward:"
echo "  ${UPLINK_INTERFACE}:${PAPERLESS_PORT} -> ${PAPERLESS_IP}:${PAPERLESS_PORT}"
