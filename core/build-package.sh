#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$REPO_ROOT/config.local"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
BUILD_DIR="$SCRIPT_DIR/build"

PACKAGE_NAME="pve-setup-core"
PACKAGE_VERSION="0.1.0+$(date +%Y%m%d%H%M%S)"
PACKAGE_ROOT="$BUILD_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}"
PACKAGE_FILE="$BUILD_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}_all.deb"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Missing configuration:" >&2
    echo "  $CONFIG" >&2
    exit 1
fi

if [[ ! -d "$TEMPLATE_DIR" ]]; then
    echo "ERROR: Missing template directory:" >&2
    echo "  $TEMPLATE_DIR" >&2
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

    chmod --reference="$source" "$destination"
}


#
# ---------------------------------------------------------------------------
# Build root
# ---------------------------------------------------------------------------
#
# core/templates/ is treated as if it were the filesystem root:
#
#   core/templates/etc/... -> /etc/...
#   core/templates/usr/... -> /usr/...
#
# Templates are rendered into a temporary package root. The resulting files
# are placed directly in the .deb, so dpkg owns them and can remove obsolete
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
Depends: bash, coreutils, iproute2, iptables, procps, systemd
Description: Local Proxmox host configuration
 Rendered host configuration managed by the pve-setup repository.
EOF

cat > "$PACKAGE_ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

systemctl daemon-reload

systemctl enable getty@tty1.service >/dev/null 2>&1 || true
systemctl restart getty@tty1.service >/dev/null 2>&1 || true

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
