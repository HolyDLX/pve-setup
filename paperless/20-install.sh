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

if [[ ! -f "$PAPERLESS_CONFIG" ]]; then
    echo "Missing Paperless configuration:"
    echo "  $PAPERLESS_CONFIG"
    echo
    echo "Run ./paperless/configure.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CORE_CONFIG"

# shellcheck source=/dev/null
source "$PAPERLESS_CONFIG"


#
# ---------------------------------------------------------------------------
# Local host directories
# ---------------------------------------------------------------------------
#
# These directories are bind-mounted into the unprivileged LXC.
#
# UID/GID 1000 inside the LXC maps to 101000 on the Proxmox host with the
# default unprivileged-container ID mapping. Paperless uses UID/GID 1000 for
# its application files, so the host directories are owned by that mapped ID.
#

echo
echo "Preparing Paperless host directories..."

mkdir -p \
    "$PAPERLESS_CONSUME_HOST_PATH" \
    "$PAPERLESS_STORAGE_HOST_PATH/data" \
    "$PAPERLESS_STORAGE_HOST_PATH/media"

chown -R 101000:101000 \
    "$PAPERLESS_CONSUME_HOST_PATH" \
    "$PAPERLESS_STORAGE_HOST_PATH"

chmod 0750 \
    "$PAPERLESS_CONSUME_HOST_PATH" \
    "$PAPERLESS_STORAGE_HOST_PATH" \
    "$PAPERLESS_STORAGE_HOST_PATH/data" \
    "$PAPERLESS_STORAGE_HOST_PATH/media"

echo "  [OK] Consume: $PAPERLESS_CONSUME_HOST_PATH"
echo "  [OK] Storage: $PAPERLESS_STORAGE_HOST_PATH"


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

    "$SCRIPT_DIR/_install-lxc.sh"
fi


#
# ---------------------------------------------------------------------------
# LXC mount points
# ---------------------------------------------------------------------------
#
# mp0 is the recursive Paperless consume directory.
# mp1 contains Paperless application data and document media.
#

echo
echo "Configuring Paperless LXC mount points..."

WAS_RUNNING=false

if [[ "$(pct status "$PAPERLESS_CTID" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
    WAS_RUNNING=true
    pct stop "$PAPERLESS_CTID"
fi

pct set "$PAPERLESS_CTID" \
    -mp0 "${PAPERLESS_CONSUME_HOST_PATH},mp=/opt/paperless/consume" \
    -mp1 "${PAPERLESS_STORAGE_HOST_PATH},mp=/opt/paperless/storage"

if $WAS_RUNNING; then
    pct start "$PAPERLESS_CTID"

    echo "Waiting for container..."

    for _ in $(seq 1 30); do
        if pct exec "$PAPERLESS_CTID" -- true 2>/dev/null; then
            break
        fi

        sleep 1
    done

    pct exec "$PAPERLESS_CTID" -- true
fi

echo "  [OK] /opt/paperless/consume"
echo "  [OK] /opt/paperless/storage"


#
# ---------------------------------------------------------------------------
# Build package
# ---------------------------------------------------------------------------
#

echo
echo "Building Paperless host package..."

PACKAGE="$("$SCRIPT_DIR/_build-package.sh")"

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
echo
echo "Host paths:"
echo "  Consume:   $PAPERLESS_CONSUME_HOST_PATH"
echo "  Storage:   $PAPERLESS_STORAGE_HOST_PATH"
