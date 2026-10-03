#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST_CONFIG="$REPO_ROOT/config.local"

if [[ ! -f "$HOST_CONFIG" ]]; then
    echo "ERROR: Missing host configuration:"
    echo "  $HOST_CONFIG"
    exit 1
fi

# shellcheck source=/dev/null
source "$HOST_CONFIG"

WPA_CONFIG="/etc/wpa_supplicant/wpa_supplicant-${UPLINK_INTERFACE}.conf"
INTERFACE_CONFIG="/etc/network/interfaces.d/05-${UPLINK_INTERFACE}"

PROFILE_DIR="/etc/pve-setup/wifi-profiles"
ACTION_SCRIPT="/usr/local/sbin/pve-wifi-action"
SERVICE_TEMPLATE="/etc/systemd/system/pve-wifi-dispatcher@.service"

mkdir -p "$PROFILE_DIR"
chmod 700 "$PROFILE_DIR"


validate_interface() {
    if [[ ! -d "/sys/class/net/$UPLINK_INTERFACE" ]]; then
        echo "ERROR: Interface '$UPLINK_INTERFACE' does not exist."
        exit 1
    fi
}


profile_name_for_ssid() {
    local ssid="$1"

    printf '%s' "$ssid" \
        | sha256sum \
        | awk '{print $1}'
}


ssid_to_base64() {
    printf '%s' "$1" | base64 -w0
}


get_current_ssid() {
    wpa_cli -i "$UPLINK_INTERFACE" status 2>/dev/null \
        | sed -n 's/^ssid=//p' \
        | head -n1
}


get_first_configured_ssid() {
    sed -n 's/^[[:space:]]*ssid="\([^"]*\)".*/\1/p' "$WPA_CONFIG" \
        | head -n1
}


get_current_dns() {
    awk '/^nameserver / { print $2; exit }' /etc/resolv.conf
}


save_profile() {
    local ssid="$1"
    local mode="$2"
    local address="${3:-}"
    local gateway="${4:-}"
    local dns="${5:-}"

    local profile_id
    local profile_file
    local ssid_base64

    profile_id="$(profile_name_for_ssid "$ssid")"
    profile_file="$PROFILE_DIR/${profile_id}.conf"
    ssid_base64="$(ssid_to_base64 "$ssid")"

    cat > "$profile_file" <<EOF
SSID_BASE64="$ssid_base64"
MODE="$mode"
ADDRESS="$address"
GATEWAY="$gateway"
DNS="$dns"
EOF

    chmod 600 "$profile_file"

    echo "  [OK] Profile stored: $profile_file"
}


install_dhcp_client() {
    if command -v dhclient >/dev/null 2>&1; then
        return
    fi

    echo
    echo "DHCP client is required for DHCP Wi-Fi profiles."
    echo "Installing isc-dhcp-client..."

    if ! apt install -y isc-dhcp-client; then
        echo
        echo "ERROR: Could not install isc-dhcp-client."
        exit 1
    fi

    echo "  [OK] DHCP client installed"
}


install_action_script() {
    cat > "$ACTION_SCRIPT" <<'EOF'
#!/bin/bash
set -u

IFACE="${1:-}"
EVENT="${2:-}"

PROFILE_DIR="/etc/pve-setup/wifi-profiles"
DHCLIENT_PID="/run/pve-wifi-dhclient-${IFACE}.pid"

log() {
    logger -t pve-wifi "$*"
}


stop_dhcp() {
    if [[ -f "$DHCLIENT_PID" ]]; then
        PID="$(cat "$DHCLIENT_PID" 2>/dev/null || true)"

        if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
        fi

        rm -f "$DHCLIENT_PID"
    fi
}


clear_network_configuration() {
    stop_dhcp

    ip route del default dev "$IFACE" 2>/dev/null || true
    ip addr flush dev "$IFACE" scope global 2>/dev/null || true
}


find_profile() {
    local wanted_ssid="$1"
    local file

    for file in "$PROFILE_DIR"/*.conf; do
        [[ -f "$file" ]] || continue

        unset SSID_BASE64 MODE ADDRESS GATEWAY DNS

        # shellcheck source=/dev/null
        source "$file"

        PROFILE_SSID="$(
            printf '%s' "$SSID_BASE64" \
                | base64 -d 2>/dev/null || true
        )"

        if [[ "$PROFILE_SSID" == "$wanted_ssid" ]]; then
            printf '%s' "$file"
            return 0
        fi
    done

    return 1
}


if [[ -z "$IFACE" ]]; then
    exit 1
fi


if [[ "$EVENT" == "DISCONNECTED" ]]; then
    log "$IFACE disconnected"

    clear_network_configuration
    exit 0
fi


if [[ "$EVENT" != "CONNECTED" ]]; then
    exit 0
fi


SSID="$(
    wpa_cli -i "$IFACE" status 2>/dev/null \
        | sed -n 's/^ssid=//p' \
        | head -n1
)"

if [[ -z "$SSID" ]]; then
    log "CONNECTED event received on $IFACE, but no SSID was found"
    exit 1
fi


PROFILE="$(
    find_profile "$SSID" || true
)"

if [[ -z "$PROFILE" ]]; then
    log "No network profile exists for SSID '$SSID'"
    clear_network_configuration
    exit 1
fi


unset SSID_BASE64 MODE ADDRESS GATEWAY DNS

# shellcheck source=/dev/null
source "$PROFILE"

log "$IFACE connected to '$SSID' using mode '$MODE'"

clear_network_configuration


case "$MODE" in

    dhcp)
        if ! command -v dhclient >/dev/null 2>&1; then
            log "dhclient is unavailable"
            exit 1
        fi

        log "Requesting DHCP lease on $IFACE"

        dhclient \
            -4 \
            -nw \
            -pf "$DHCLIENT_PID" \
            "$IFACE"
        ;;


    static)
        if [[ -z "${ADDRESS:-}" || -z "${GATEWAY:-}" ]]; then
            log "Static profile '$SSID' is incomplete"
            exit 1
        fi

        log "Applying static address $ADDRESS"

        ip addr add "$ADDRESS" dev "$IFACE"

        ip route replace \
            default \
            via "$GATEWAY" \
            dev "$IFACE"

        if [[ -n "${DNS:-}" ]]; then
            printf 'nameserver %s\n' "$DNS" > /etc/resolv.conf
        fi
        ;;


    *)
        log "Unknown profile mode '$MODE'"
        exit 1
        ;;

esac
EOF

    chmod 0755 "$ACTION_SCRIPT"

    echo "  [OK] Installed $ACTION_SCRIPT"
}


install_dispatcher_service() {
    WPA_CLI="$(command -v wpa_cli)"

    cat > "$SERVICE_TEMPLATE" <<EOF
[Unit]
Description=Wi-Fi network profile dispatcher for %I
Requires=wpa_supplicant@%i.service
After=wpa_supplicant@%i.service

[Service]
Type=simple
ExecStart=$WPA_CLI -i %I -a $ACTION_SCRIPT
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$SERVICE_TEMPLATE"

    systemctl daemon-reload

    systemctl enable \
        "pve-wifi-dispatcher@${UPLINK_INTERFACE}.service" \
        >/dev/null

    echo "  [OK] Wi-Fi dispatcher service installed"
}


migrate_primary_wifi() {
    local marker="$PROFILE_DIR/.primary-migrated"

    if [[ -f "$marker" ]]; then
        return
    fi

    echo
    echo "Migrating existing primary Wi-Fi..."

    PRIMARY_SSID="$(get_current_ssid)"

    if [[ -z "$PRIMARY_SSID" ]]; then
        PRIMARY_SSID="$(get_first_configured_ssid)"
    fi

    if [[ -z "$PRIMARY_SSID" ]]; then
        echo "ERROR: Could not determine the existing Wi-Fi SSID."
        exit 1
    fi

    PRIMARY_DNS="$(get_current_dns)"
    PRIMARY_DNS="${PRIMARY_DNS:-1.1.1.1}"

    echo
    echo "Existing Wi-Fi:"
    echo
    echo "  SSID:    $PRIMARY_SSID"
    echo "  Address: $HOST_ADDRESS"
    echo "  Gateway: $HOST_GATEWAY"
    echo "  DNS:     $PRIMARY_DNS"
    echo
    echo "This will become the primary static Wi-Fi profile."

    save_profile \
        "$PRIMARY_SSID" \
        "static" \
        "$HOST_ADDRESS" \
        "$HOST_GATEWAY" \
        "$PRIMARY_DNS"

    #
    # IP configuration is now controlled by the Wi-Fi dispatcher rather
    # than directly by ifupdown.
    #
    cat > "$INTERFACE_CONFIG" <<EOF
auto $UPLINK_INTERFACE
iface $UPLINK_INTERFACE inet manual
EOF

    chmod 0644 "$INTERFACE_CONFIG"

    touch "$marker"

    echo
    echo "  [OK] Existing Wi-Fi migrated"
}


ssid_already_configured() {
    local ssid="$1"

    grep -Fq \
        "ssid=\"$ssid\"" \
        "$WPA_CONFIG"
}


add_wpa_network() {
    local ssid="$1"
    local password="$2"
    local priority="$3"

    local temp_file

    temp_file="$(mktemp)"

    wpa_passphrase "$ssid" "$password" \
        | grep -v '^[[:space:]]*#psk=' \
        | sed "/^}/i\\    priority=$priority" \
        > "$temp_file"

    {
        echo
        cat "$temp_file"
    } >> "$WPA_CONFIG"

    rm -f "$temp_file"

    chmod 600 "$WPA_CONFIG"
}


add_network_profile() {
    echo
    echo "============================================================"
    echo "Add additional Wi-Fi"
    echo "============================================================"
    echo

    read -r -p "SSID: " WIFI_SSID

    if [[ -z "$WIFI_SSID" ]]; then
        echo "ERROR: SSID cannot be empty."
        exit 1
    fi

    if ssid_already_configured "$WIFI_SSID"; then
        echo
        echo "SSID '$WIFI_SSID' already exists in wpa_supplicant."
        echo "The IP profile will still be created or updated."
        ADD_WPA=0
    else
        ADD_WPA=1
    fi

    if [[ "$ADD_WPA" -eq 1 ]]; then
        read -r -s -p "Wi-Fi password: " WIFI_PASSWORD
        echo

        read -r -p "Priority [0]: " WIFI_PRIORITY
        WIFI_PRIORITY="${WIFI_PRIORITY:-0}"
    fi

    echo
    echo "IP configuration:"
    echo
    echo "  1) DHCP"
    echo "  2) Static"
    echo

    read -r -p "Mode [1]: " IP_MODE
    IP_MODE="${IP_MODE:-1}"

    case "$IP_MODE" in

        1)
            install_dhcp_client

            save_profile \
                "$WIFI_SSID" \
                "dhcp"
            ;;


        2)
            read -r -p "IP address with prefix: " STATIC_ADDRESS
            read -r -p "Gateway: " STATIC_GATEWAY
            read -r -p "DNS server [1.1.1.1]: " STATIC_DNS

            STATIC_DNS="${STATIC_DNS:-1.1.1.1}"

            save_profile \
                "$WIFI_SSID" \
                "static" \
                "$STATIC_ADDRESS" \
                "$STATIC_GATEWAY" \
                "$STATIC_DNS"
            ;;


        *)
            echo "ERROR: Invalid mode."
            exit 1
            ;;

    esac

    if [[ "$ADD_WPA" -eq 1 ]]; then
        add_wpa_network \
            "$WIFI_SSID" \
            "$WIFI_PASSWORD" \
            "$WIFI_PRIORITY"

        unset WIFI_PASSWORD

        echo "  [OK] Wi-Fi credentials added"
    fi
}


validate_interface

if [[ ! -f "$WPA_CONFIG" ]]; then
    echo "ERROR: Missing wpa_supplicant configuration:"
    echo "  $WPA_CONFIG"
    exit 1
fi

install_action_script
install_dispatcher_service
migrate_primary_wifi
add_network_profile


echo
echo "Reloading wpa_supplicant configuration..."

if ! wpa_cli \
    -i "$UPLINK_INTERFACE" \
    reconfigure \
    >/dev/null
then
    echo "WARNING: Could not reload wpa_supplicant immediately."
    echo "The configuration will still be used after reboot."
fi


echo
echo "Restarting Wi-Fi dispatcher..."

systemctl restart \
    "pve-wifi-dispatcher@${UPLINK_INTERFACE}.service"


#
# wpa_cli's action mode only reacts to future events. If Wi-Fi is already
# connected, explicitly apply the matching profile now.
#
CURRENT_SSID="$(get_current_ssid)"

if [[ -n "$CURRENT_SSID" ]]; then
    echo
    echo "Applying profile for current connection:"
    echo "  $CURRENT_SSID"

    "$ACTION_SCRIPT" \
        "$UPLINK_INTERFACE" \
        CONNECTED
fi


echo
echo "============================================================"
echo "Additional Wi-Fi configured."
echo "============================================================"
echo
echo "Wi-Fi networks are selected automatically by wpa_supplicant."
echo "Each SSID has its own IP configuration under:"
echo
echo "  $PROFILE_DIR"
echo
echo "Current primary Wi-Fi remains configured with:"
echo
echo "  $HOST_ADDRESS"
echo
echo "Additional DHCP networks will obtain their address,"
echo "gateway and DNS settings automatically."