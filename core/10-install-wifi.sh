#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST_CONFIG="$REPO_ROOT/config.local"
CORE_CONFIG="$SCRIPT_DIR/config.local"

if [[ ! -f "$HOST_CONFIG" ]]; then
    echo "ERROR: Missing host configuration:"
    echo "  $HOST_CONFIG"
    echo
    echo "Run ./core/configure.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "$HOST_CONFIG"


command_exists() {
    command -v "$1" >/dev/null 2>&1
}


validate_interface() {
    local interface="$1"

    if [[ ! -d "/sys/class/net/$interface" ]]; then
        echo "ERROR: Interface '$interface' does not exist."
        echo
        echo "Available interfaces:"
        ip -br link
        exit 1
    fi
}


validate_address_and_gateway() {
    local address="$1"
    local gateway="$2"

    if ! python3 - "$address" "$gateway" <<'PY'
import ipaddress
import sys

address = sys.argv[1]
gateway = sys.argv[2]

try:
    interface = ipaddress.ip_interface(address)
except ValueError as exc:
    print(f"ERROR: Invalid IP/prefix '{address}': {exc}")
    sys.exit(1)

try:
    gateway_ip = ipaddress.ip_address(gateway)
except ValueError as exc:
    print(f"ERROR: Invalid gateway '{gateway}': {exc}")
    sys.exit(1)

if interface.version != gateway_ip.version:
    print("ERROR: Address and gateway use different IP versions.")
    sys.exit(1)

if gateway_ip not in interface.network:
    print()
    print("ERROR: Gateway is not reachable through the configured subnet.")
    print()
    print(f"  Address: {interface}")
    print(f"  Network: {interface.network}")
    print(f"  Gateway: {gateway_ip}")
    sys.exit(1)

if gateway_ip == interface.ip:
    print("ERROR: Gateway and interface address are identical.")
    sys.exit(1)

print(f"  [OK] Address: {interface}")
print(f"  [OK] Network: {interface.network}")
print(f"  [OK] Gateway: {gateway_ip}")
PY
    then
        exit 1
    fi
}


disable_source_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        echo "  Disabling $(basename "$file")..."
        mv "$file" "${file}.disabled"
    fi
}


configure_proxmox_repositories() {
    echo
    echo "Configuring Proxmox repositories..."

    disable_source_file /etc/apt/sources.list.d/pve-enterprise.sources
    disable_source_file /etc/apt/sources.list.d/ceph.sources
    disable_source_file /etc/apt/sources.list.d/pve-enterprise.list
    disable_source_file /etc/apt/sources.list.d/ceph.list

    rm -f /etc/apt/sources.list.d/pve-no-subscription.sources

    cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

    echo "  [OK] pve-no-subscription enabled"
}


load_core_defaults() {
    ETH_INTERFACE=""
    ETH_ADDRESS=""
    ETH_GATEWAY=""
    ETH_DNS="1.1.1.1"

    if [[ -f "$CORE_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$CORE_CONFIG"

        echo
        echo "Found previous temporary network settings:"
        echo
        echo "  Interface: ${ETH_INTERFACE:-}"
        echo "  Address:   ${ETH_ADDRESS:-}"
        echo "  Gateway:   ${ETH_GATEWAY:-}"
        echo "  DNS:       ${ETH_DNS:-}"
    fi
}


save_core_defaults() {
    cat > "$CORE_CONFIG" <<EOF
ETH_INTERFACE="$ETH_INTERFACE"
ETH_ADDRESS="$ETH_ADDRESS"
ETH_GATEWAY="$ETH_GATEWAY"
ETH_DNS="$ETH_DNS"
EOF

    chmod 600 "$CORE_CONFIG"
}


prompt_with_default() {
    local prompt="$1"
    local current="$2"
    local result

    if [[ -n "$current" ]]; then
        read -r -p "$prompt [$current]: " result
        printf '%s' "${result:-$current}"
    else
        read -r -p "$prompt: " result
        printf '%s' "$result"
    fi
}


install_wifi_dependencies() {
    echo
    echo "Wi-Fi dependencies are not installed."
    echo
    echo "A temporary Ethernet connection is required to install them."
    echo
    echo "Connect the USB Ethernet adapter and network cable."
    echo
    read -r -p "Press Enter when connected..."

    echo
    echo "Available interfaces:"
    echo
    ip -br link

    load_core_defaults

    echo

    ETH_INTERFACE="$(
        prompt_with_default \
            "Temporary Ethernet interface" \
            "$ETH_INTERFACE"
    )"

    validate_interface "$ETH_INTERFACE"

    ETH_ADDRESS="$(
        prompt_with_default \
            "Temporary IP with prefix" \
            "$ETH_ADDRESS"
    )"

    ETH_GATEWAY="$(
        prompt_with_default \
            "Temporary gateway" \
            "$ETH_GATEWAY"
    )"

    ETH_DNS="$(
        prompt_with_default \
            "Temporary DNS server" \
            "$ETH_DNS"
    )"

    #
    # Save immediately so retries reuse the same answers.
    #
    save_core_defaults

    echo
    echo "Validating temporary network configuration..."

    validate_address_and_gateway "$ETH_ADDRESS" "$ETH_GATEWAY"

    echo
    echo "Preparing temporary network..."

    if ip link show vmbr0 >/dev/null 2>&1; then
        echo "  Temporarily disabling installer-created vmbr0..."

        ip link set vmbr0 down 2>/dev/null || true
        ip addr flush dev vmbr0 2>/dev/null || true
    fi

    echo "  Bringing up $ETH_INTERFACE..."

    if ! ip link set "$ETH_INTERFACE" up; then
        echo "ERROR: Could not bring '$ETH_INTERFACE' up."
        exit 1
    fi

    ip addr flush dev "$ETH_INTERFACE" 2>/dev/null || true

    echo "  Assigning $ETH_ADDRESS..."

    if ! ip addr add "$ETH_ADDRESS" dev "$ETH_INTERFACE"; then
        echo "ERROR: Could not assign '$ETH_ADDRESS'."
        exit 1
    fi

    echo
    echo "Connected route:"
    ip -4 route show dev "$ETH_INTERFACE"
    echo

    echo "  Configuring default route via $ETH_GATEWAY..."

    if ! ip route replace default via "$ETH_GATEWAY" dev "$ETH_INTERFACE"; then
        echo
        echo "ERROR: Could not configure the default route."
        echo
        echo "Interface:"
        ip -br addr show "$ETH_INTERFACE"
        echo
        echo "Routing table:"
        ip -4 route
        exit 1
    fi

    echo "  Configuring temporary DNS: $ETH_DNS"

    printf 'nameserver %s\n' "$ETH_DNS" > /etc/resolv.conf

    echo
    echo "Testing temporary network..."

    if ping -c 1 -W 3 "$ETH_GATEWAY" >/dev/null 2>&1; then
        echo "  [OK] Gateway reachable"
    else
        echo "  [FAIL] Gateway is not responding: $ETH_GATEWAY"
        exit 1
    fi

    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        echo "  [OK] Internet reachable"
    else
        echo "  [FAIL] Gateway works, but Internet access does not."
        exit 1
    fi

    if getent hosts debian.org >/dev/null 2>&1; then
        echo "  [OK] DNS resolution works"
    else
        echo "  [FAIL] Internet works, but DNS resolution does not."
        echo "         DNS server: $ETH_DNS"
        exit 1
    fi

    echo
    echo "Temporary network is working."

    configure_proxmox_repositories

    echo
    echo "Updating package lists..."

    if ! apt update; then
        echo
        echo "ERROR: apt update failed."
        echo
        echo "APT source files:"
        echo

        for file in \
            /etc/apt/sources.list \
            /etc/apt/sources.list.d/*.list \
            /etc/apt/sources.list.d/*.sources
        do
            [[ -f "$file" ]] || continue

            echo "----- $file -----"
            cat "$file"
            echo
        done

        exit 1
    fi

    echo
    echo "Installing Wi-Fi dependencies..."

    if ! apt install -y \
        wpasupplicant \
        iw \
        rfkill \
        curl \
        ca-certificates \
        git
    then
        echo
        echo "ERROR: Failed to install Wi-Fi dependencies."
        exit 1
    fi

    echo
    echo "Wi-Fi dependencies installed."
}


#
# Bootstrap Wi-Fi support if necessary.
#
if ! command_exists wpa_supplicant \
    || ! command_exists wpa_passphrase \
    || ! command_exists iw \
    || ! command_exists rfkill
then
    install_wifi_dependencies
else
    echo "Wi-Fi dependencies are already installed."
fi


#
# Persistent Wi-Fi configuration.
#
echo
echo "Configuring permanent Wi-Fi uplink:"
echo
echo "  Interface: $UPLINK_INTERFACE"
echo "  Address:   $HOST_ADDRESS"
echo "  Gateway:   $HOST_GATEWAY"
echo

validate_interface "$UPLINK_INTERFACE"
validate_address_and_gateway "$HOST_ADDRESS" "$HOST_GATEWAY"

read -r -p "Wi-Fi SSID: " WIFI_SSID
read -r -s -p "Wi-Fi password: " WIFI_PASSWORD
echo

WPA_CONFIG="/etc/wpa_supplicant/wpa_supplicant-${UPLINK_INTERFACE}.conf"
INTERFACE_CONFIG="/etc/network/interfaces.d/05-${UPLINK_INTERFACE}"

echo
echo "Creating Wi-Fi authentication configuration..."

mkdir -p /etc/wpa_supplicant

if ! wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" \
    | grep -v '^[[:space:]]*#psk=' \
    > "$WPA_CONFIG"
then
    unset WIFI_PASSWORD

    echo
    echo "ERROR: Failed to generate wpa_supplicant configuration."
    exit 1
fi

chmod 600 "$WPA_CONFIG"
unset WIFI_PASSWORD

echo "Creating persistent interface configuration..."

cat > "$INTERFACE_CONFIG" <<EOF
auto $UPLINK_INTERFACE
iface $UPLINK_INTERFACE inet static
    address $HOST_ADDRESS
    gateway $HOST_GATEWAY
EOF

chmod 0644 "$INTERFACE_CONFIG"

echo "Enabling Wi-Fi service..."

if ! systemctl enable "wpa_supplicant@${UPLINK_INTERFACE}.service"; then
    echo
    echo "ERROR: Failed to enable wpa_supplicant."
    exit 1
fi

echo
echo "============================================================"
echo "Wi-Fi installation complete."
echo "============================================================"
echo
echo "Permanent configuration:"
echo
echo "  Interface: $UPLINK_INTERFACE"
echo "  Address:   $HOST_ADDRESS"
echo "  Gateway:   $HOST_GATEWAY"
echo
echo "Temporary Ethernet settings are stored in:"
echo "  $CORE_CONFIG"
echo
echo "They will be offered as defaults on the next run."
echo
echo "Next:"
echo
echo "  ./core/install-core.sh"
echo