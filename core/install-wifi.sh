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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_dependencies() {
    echo
    echo "Wi-Fi dependencies are missing."
    echo
    echo "Connect a temporary Ethernet adapter/cable with Internet access."
    echo
    read -r -p "Press Enter when connected..."

    echo
    ip -br link
    echo

    read -r -p "Temporary Ethernet interface: " ETH_INTERFACE
    read -r -p "Temporary IP with prefix: " ETH_ADDRESS
    read -r -p "Temporary gateway: " ETH_GATEWAY
    read -r -p "Temporary DNS server [1.1.1.1]: " ETH_DNS
    ETH_DNS="${ETH_DNS:-1.1.1.1}"

    ip link set "$ETH_INTERFACE" up
    ip addr flush dev "$ETH_INTERFACE"
    ip addr add "$ETH_ADDRESS" dev "$ETH_INTERFACE"
    ip route replace default via "$ETH_GATEWAY" dev "$ETH_INTERFACE"

    printf 'nameserver %s\n' "$ETH_DNS" > /etc/resolv.conf

    echo
    echo "Testing temporary network..."

    ping -c 1 -W 3 "$ETH_GATEWAY" >/dev/null
    ping -c 1 -W 3 1.1.1.1 >/dev/null
    getent hosts debian.org >/dev/null

    echo "Installing Wi-Fi dependencies..."

    apt update
    apt install -y \
        wpasupplicant \
        iw \
        rfkill \
        curl \
        ca-certificates \
        git
}

if ! command_exists wpa_supplicant \
    || ! command_exists wpa_passphrase \
    || ! command_exists iw \
    || ! command_exists rfkill
then
    install_dependencies
fi

echo
echo "Configuring Wi-Fi interface:"
echo "  $UPLINK_INTERFACE"
echo

read -r -p "Wi-Fi SSID: " WIFI_SSID
read -r -s -p "Wi-Fi password: " WIFI_PASSWORD
echo

WPA_CONFIG="/etc/wpa_supplicant/wpa_supplicant-${UPLINK_INTERFACE}.conf"
INTERFACE_CONFIG="/etc/network/interfaces.d/05-${UPLINK_INTERFACE}"

mkdir -p /etc/wpa_supplicant

wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" \
    | grep -v '^[[:space:]]*#psk=' \
    > "$WPA_CONFIG"

chmod 600 "$WPA_CONFIG"
unset WIFI_PASSWORD

cat > "$INTERFACE_CONFIG" <<EOF
auto $UPLINK_INTERFACE
iface $UPLINK_INTERFACE inet static
    address $HOST_ADDRESS
    gateway $HOST_GATEWAY
EOF

chmod 0644 "$INTERFACE_CONFIG"

systemctl enable "wpa_supplicant@${UPLINK_INTERFACE}.service"

echo
echo "Wi-Fi installation complete."
echo "A reboot is recommended."
