#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CORE_CONFIG="$REPO_ROOT/config.local"
PAPERLESS_CONFIG="$SCRIPT_DIR/config.local"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
BUILD_DIR="$SCRIPT_DIR/build"

PACKAGE_NAME="pve-setup-paperless"
PACKAGE_VERSION="0.1.0+$(date +%Y%m%d%H%M%S)"
PACKAGE_ROOT="$BUILD_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}"
PACKAGE_FILE="$BUILD_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}_all.deb"

if [[ ! -f "$CORE_CONFIG" ]]; then
    echo "ERROR: Missing core configuration:" >&2
    echo "  $CORE_CONFIG" >&2
    exit 1
fi

if [[ ! -f "$PAPERLESS_CONFIG" ]]; then
    echo "ERROR: Missing Paperless configuration:" >&2
    echo "  $PAPERLESS_CONFIG" >&2
    exit 1
fi

if [[ ! -d "$TEMPLATE_DIR" ]]; then
    echo "ERROR: Missing template directory:" >&2
    echo "  $TEMPLATE_DIR" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CORE_CONFIG"

# shellcheck source=/dev/null
source "$PAPERLESS_CONFIG"


render() {
    local source="$1"
    local destination="$2"

    sed \
        -e "s|{{UPLINK_INTERFACE}}|$UPLINK_INTERFACE|g" \
        -e "s|{{VM_BRIDGE}}|$VM_BRIDGE|g" \
        -e "s|{{VM_NETWORK}}|$VM_NETWORK|g" \
        -e "s|{{VM_GATEWAY}}|$VM_GATEWAY|g" \
        -e "s|{{PAPERLESS_CTID}}|$PAPERLESS_CTID|g" \
        -e "s|{{PAPERLESS_IP}}|$PAPERLESS_IP|g" \
        -e "s|{{PAPERLESS_PORT}}|$PAPERLESS_PORT|g" \
        -e "s|{{PAPERLESS_HOSTNAME}}|$PAPERLESS_HOSTNAME|g" \
        "$source" > "$destination"

    chmod --reference="$source" "$destination"
}


#
# ---------------------------------------------------------------------------
# Build root
# ---------------------------------------------------------------------------
#
# paperless/templates/ is treated as if it were the filesystem root:
#
#   paperless/templates/etc/... -> /etc/...
#
# Templates are rendered into a temporary package root. The resulting files
# are placed directly in the .deb, so dpkg owns them and removes obsolete
# files automatically during upgrades.
#

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT"
mkdir -p "$BUILD_DIR"

while IFS= read -r -d '' directory; do
    relative="${directory#$TEMPLATE_DIR}"

    if [[ -n "$relative" ]]; then
        mkdir -p "$PACKAGE_ROOT$relative"
    fi
done < <(
    find "$TEMPLATE_DIR" -type d -print0
)

while IFS= read -r -d '' source; do
    relative="${source#$TEMPLATE_DIR/}"
    destination="$PACKAGE_ROOT/$relative"

    mkdir -p "$(dirname "$destination")"

    render "$source" "$destination"
done < <(
    find "$TEMPLATE_DIR" -type f -print0
)


#
# ---------------------------------------------------------------------------
# Debian package metadata
# ---------------------------------------------------------------------------
#

mkdir -p "$PACKAGE_ROOT/DEBIAN"

cat > "$PACKAGE_ROOT/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Local Administrator <root@localhost>
Depends: pve-setup-core, bash, curl, iptables, pve-container
Description: Local Paperless host integration
 Host-side networking and tty monitor integration for Paperless.
EOF

#
# Remove the currently active forwarding rules before an upgrade/removal.
# During an upgrade this runs while the old rendered hook is still installed,
# so changed ports, IP addresses or interfaces do not leave stale rules behind.
#
cat > "$PACKAGE_ROOT/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e

if [ -x /etc/network/if-down.d/network-paperless ]; then
    IFACE="$UPLINK_INTERFACE" /etc/network/if-down.d/network-paperless || true
fi

exit 0
EOF

chmod 0755 "$PACKAGE_ROOT/DEBIAN/prerm"

#
# The uplink may already be up when this package is installed or upgraded.
# Apply the newly rendered forwarding rules immediately instead of waiting
# for the next interface-up event.
#
cat > "$PACKAGE_ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e

if [ -x /etc/network/if-up.d/network-paperless ]; then
    IFACE="$UPLINK_INTERFACE" /etc/network/if-up.d/network-paperless || true
fi

exit 0
EOF

chmod 0755 "$PACKAGE_ROOT/DEBIAN/postinst"


#
# ---------------------------------------------------------------------------
# Build package
# ---------------------------------------------------------------------------
#

rm -f "$PACKAGE_FILE"

dpkg-deb --root-owner-group --build \
    "$PACKAGE_ROOT" \
    "$PACKAGE_FILE" \
    >/dev/null

printf '%s\n' "$PACKAGE_FILE"
