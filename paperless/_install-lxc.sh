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
    echo "Missing:"
    echo "  $CORE_CONFIG"
    exit 1
fi

if [[ ! -f "$PAPERLESS_CONFIG" ]]; then
    echo "Missing:"
    echo "  $PAPERLESS_CONFIG"
    echo
    echo "Run ./paperless/configure.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$CORE_CONFIG"

# shellcheck source=/dev/null
source "$PAPERLESS_CONFIG"

DEFAULT_TEMPLATE_STORAGE="local"
DEFAULT_ROOTFS_STORAGE="local-lvm"

DISK_GB=64
CORES=2
MEMORY_MB=4096
SWAP_MB=1024

if pct status "$PAPERLESS_CTID" &>/dev/null; then
    echo "Container $PAPERLESS_CTID already exists."
    exit 1
fi

read -r -p "Paperless admin username [admin]: " PAPERLESS_ADMIN_USER
PAPERLESS_ADMIN_USER="${PAPERLESS_ADMIN_USER:-admin}"

while true; do
    read -r -s -p "Paperless admin password: " PAPERLESS_ADMIN_PASSWORD
    echo

    read -r -s -p "Repeat password: " PASSWORD_CONFIRM
    echo

    if [[ "$PAPERLESS_ADMIN_PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
        break
    fi

    echo "Passwords do not match."
done

unset PASSWORD_CONFIRM

read -r -p \
    "Template storage [$DEFAULT_TEMPLATE_STORAGE]: " \
    TEMPLATE_STORAGE

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}"

read -r -p \
    "Root filesystem storage [$DEFAULT_ROOTFS_STORAGE]: " \
    ROOTFS_STORAGE

ROOTFS_STORAGE="${ROOTFS_STORAGE:-$DEFAULT_ROOTFS_STORAGE}"

HOST_IP="${HOST_ADDRESS%%/*}"
PAPERLESS_URL="http://${HOST_IP}:${PAPERLESS_PORT}"

echo
echo "Updating appliance template list..."

pveam update

TEMPLATE=$(
    pveam available --section system |
    awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {
        print $2
    }' |
    sort -V |
    tail -n 1
)

if [[ -z "$TEMPLATE" ]]; then
    echo "Unable to find a Debian 13 LXC template."
    exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" | grep -Fq "$TEMPLATE"; then
    echo "Downloading $TEMPLATE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

echo
echo "Creating LXC..."

pct create "$PAPERLESS_CTID" "$TEMPLATE_REF" \
    --hostname "$PAPERLESS_HOSTNAME" \
    --ostype debian \
    --unprivileged 1 \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap "$SWAP_MB" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --features nesting=1,keyctl=1 \
    --net0 "name=eth0,bridge=${VM_BRIDGE},ip=${PAPERLESS_IP}/24,gw=${VM_GATEWAY}" \
    --mp0 "${PAPERLESS_CONSUME_HOST_PATH},mp=/opt/paperless/consume" \
    --mp1 "${PAPERLESS_STORAGE_HOST_PATH},mp=/opt/paperless/storage" \
    --onboot 1

pct start "$PAPERLESS_CTID"

echo "Waiting for container..."

for _ in $(seq 1 30); do
    if pct exec "$PAPERLESS_CTID" -- true 2>/dev/null; then
        break
    fi

    sleep 1
done

pct exec "$PAPERLESS_CTID" -- true

echo
echo "Updating guest..."

pct exec "$PAPERLESS_CTID" -- apt update
pct exec "$PAPERLESS_CTID" -- apt full-upgrade -y

echo
echo "Installing Docker..."

pct exec "$PAPERLESS_CTID" -- apt install -y \
    docker.io \
    docker-compose \
    curl \
    ca-certificates \
    openssl

pct exec "$PAPERLESS_CTID" -- systemctl enable --now docker

echo
echo "Preparing Paperless..."

pct exec "$PAPERLESS_CTID" -- mkdir -p \
    /opt/paperless \
    /opt/paperless/consume \
    /opt/paperless/export \
    /opt/paperless/storage/data \
    /opt/paperless/storage/media

TMPDIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMPDIR"
    unset PAPERLESS_ADMIN_PASSWORD
}

trap cleanup EXIT

curl -fsSL \
    https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docker/compose/docker-compose.postgres.yml \
    -o "$TMPDIR/docker-compose.yml"

PAPERLESS_SECRET_KEY=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 32)

# Keep PostgreSQL and Paperless credentials aligned.
sed -i \
    "s|POSTGRES_PASSWORD: paperless|POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}|" \
    "$TMPDIR/docker-compose.yml"

# Expose the selected LXC port while Paperless itself continues to listen
# on port 8000 inside its Docker container.
sed -i \
    "s|8000:8000|${PAPERLESS_PORT}:8000|" \
    "$TMPDIR/docker-compose.yml"

#
# Keep Paperless application data and document media on the host-backed
# storage mount rather than in Docker-managed named volumes.
#
sed -i \
    -e 's|      - data:/usr/src/paperless/data|      - ./storage/data:/usr/src/paperless/data|' \
    -e 's|      - media:/usr/src/paperless/media|      - ./storage/media:/usr/src/paperless/media|' \
    "$TMPDIR/docker-compose.yml"

cat > "$TMPDIR/docker-compose.env" <<EOF
PAPERLESS_URL=${PAPERLESS_URL}
PAPERLESS_TIME_ZONE=Europe/Berlin
PAPERLESS_OCR_LANGUAGE=deu+eng

PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET_KEY}

PAPERLESS_DBPASS=${POSTGRES_PASSWORD}

PAPERLESS_ADMIN_USER=${PAPERLESS_ADMIN_USER}
PAPERLESS_ADMIN_PASSWORD=${PAPERLESS_ADMIN_PASSWORD}

PAPERLESS_CONSUMER_RECURSIVE=true
EOF

chmod 600 "$TMPDIR/docker-compose.env"

pct push \
    "$PAPERLESS_CTID" \
    "$TMPDIR/docker-compose.yml" \
    /opt/paperless/docker-compose.yml

pct push \
    "$PAPERLESS_CTID" \
    "$TMPDIR/docker-compose.env" \
    /opt/paperless/docker-compose.env

pct exec "$PAPERLESS_CTID" -- \
    chmod 600 /opt/paperless/docker-compose.env

echo
echo "Pulling images..."

pct exec "$PAPERLESS_CTID" -- \
    bash -c 'cd /opt/paperless && docker compose pull'

echo
echo "Starting Paperless..."

pct exec "$PAPERLESS_CTID" -- \
    bash -c 'cd /opt/paperless && docker compose up -d'

echo
echo "Waiting for Paperless..."

for _ in $(seq 1 60); do
    if pct exec "$PAPERLESS_CTID" -- \
        curl -fsS "http://127.0.0.1:${PAPERLESS_PORT}/" \
        >/dev/null 2>&1
    then
        break
    fi

    sleep 2
done

echo
echo "Container services:"

pct exec "$PAPERLESS_CTID" -- \
    bash -c 'cd /opt/paperless && docker compose ps'

echo
echo "Paperless guest installation complete."
echo
echo "URL:        $PAPERLESS_URL"
echo "Admin user: $PAPERLESS_ADMIN_USER"
