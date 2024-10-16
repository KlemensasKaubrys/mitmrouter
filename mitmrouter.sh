#!/bin/bash

# Enhanced Wireless Access Point Setup Script
# Supports 'nat', 'proxy_arp', and 'bridge' methods
# Provides robust error handling and user feedback

# VARIABLES
# Interfaces (Set to empty to enable auto-detection)
WAN_IFACE=""          # Internet-facing interface (e.g., eth0)
LAN_IFACE=""          # Optional, if you have a LAN interface (e.g., eth1)
WIFI_IFACE=""         # Wireless interface for AP (e.g., wlan0)

# Wireless Network Configuration
WIFI_SSID="setec_astronomy"
WIFI_PASSWORD="mypassword"
COUNTRY_CODE="US"
CHANNEL="11"

# Network Configuration
LAN_IP="192.168.200.1"
LAN_SUBNET="255.255.255.0"
LAN_DHCP_START="192.168.200.10"
LAN_DHCP_END="192.168.200.100"
LAN_DNS_SERVER="1.1.1.1"

# Method Selection: Choose 'nat', 'proxy_arp', or 'bridge'
METHOD="nat"

# Configuration Files
DNSMASQ_CONF="/tmp/tmp_dnsmasq.conf"
HOSTAPD_CONF="/tmp/tmp_hostapd.conf"
IPTABLES_RULES="/tmp/iptables.rules"

# Functions for error handling and logging
function log_info {
    echo -e "\e[32m[INFO]\e[0m $1"
}

function log_error {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

function check_command {
    if ! command -v $1 &> /dev/null; then
        log_error "Command '$1' not found. Please install it and try again."
        exit 1
    fi
}

function require_sudo {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root. Use sudo."
        exit 1
    fi
}

function backup_file {
    if [ -f "$1" ]; then
        cp "$1" "$1.bak"
        log_info "Backup of $1 saved as $1.bak"
    fi
}

function restore_backup {
    if [ -f "$1.bak" ]; then
        mv "$1.bak" "$1"
        log_info "Restored backup of $1 from $1.bak"
    fi
}

require_sudo

check_command ip
check_command iw
check_command hostapd
check_command dnsmasq
check_command iptables

function detect_interfaces {
    if [ -z "$WAN_IFACE" ]; then
        WAN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
        log_info "Auto-detected WAN interface: $WAN_IFACE"
    fi

    if [ -z "$WIFI_IFACE" ]; then
        WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
        log_info "Auto-detected Wi-Fi interface: $WIFI_IFACE"
    fi

    if [ -z "$WAN_IFACE" ] || [ -z "$WIFI_IFACE" ]; then
        log_error "Could not auto-detect interfaces. Please specify them manually."
        exit 1
    fi
}

detect_interfaces

if [ "$1" != "up" ] && [ "$1" != "down" ] || [ $# != 1 ]; then
    echo "Usage: $0 <up/down>"
    exit 1
fi

function cleanup {
    log_info "Stopping services and cleaning up"
    systemctl stop hostapd dnsmasq &> /dev/null
    pkill hostapd
    pkill dnsmasq

    iptables --flush
    iptables -t nat --flush
    iptables -t mangle --flush
    iptables -X

    sysctl -w net.ipv4.ip_forward=0 &> /dev/null

    ip addr flush dev "$WIFI_IFACE"
    ip link set dev "$WIFI_IFACE" down

    if [ "$METHOD" = "bridge" ]; then
        ip link set dev br0 down &> /dev/null
        ip link delete br0 type bridge &> /dev/null
    fi

    restore_backup /etc/dnsmasq.conf

    rm -f "$DNSMASQ_CONF" "$HOSTAPD_CONF" "$IPTABLES_RULES"
}

if [ "$1" = "down" ]; then
    cleanup
    log_info "Access point stopped and cleaned up"
    exit 0
fi

function setup_ap {
    log_info "Setting up the access point using method: $METHOD"

    sysctl -w net.ipv4.ip_forward=1

    ip link set dev "$WIFI_IFACE" up
    iw dev "$WIFI_IFACE" set power_save off

    cat > "$HOSTAPD_CONF" << EOF
interface=$WIFI_IFACE
ssid=$WIFI_SSID
hw_mode=g
channel=$CHANNEL
wpa=2
wpa_passphrase=$WIFI_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
country_code=$COUNTRY_CODE
ieee80211n=1
EOF

    case "$METHOD" in
        nat)
            setup_nat
            ;;
        proxy_arp)
            setup_proxy_arp
            ;;
        bridge)
            setup_bridge
            ;;
        *)
            log_error "Invalid METHOD selected. Choose 'nat', 'proxy_arp', or 'bridge'."
            exit 1
            ;;
    esac

    log_info "Starting hostapd"
    hostapd "$HOSTAPD_CONF" &
    sleep 2

    if pgrep hostapd > /dev/null; then
        log_info "hostapd started successfully"
    else
        log_error "Failed to start hostapd. Check configuration and logs."
        exit 1
    fi
}

function setup_nat {
    log_info "Configuring NAT"

    ip addr add "$LAN_IP/24" dev "$WIFI_IFACE"

    backup_file /etc/dnsmasq.conf
    killall dnsmasq
    cat > "$DNSMASQ_CONF" << EOF
interface=$WIFI_IFACE
bind-interfaces
server=$LAN_DNS_SERVER
dhcp-range=$LAN_DHCP_START,$LAN_DHCP_END,255.255.255.0,12h
EOF

    log_info "Starting dnsmasq"
    dnsmasq -C "$DNSMASQ_CONF"

    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$WAN_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$WIFI_IFACE" -o "$WAN_IFACE" -j ACCEPT

    log_info "NAT configuration completed"
}

function setup_proxy_arp {
    log_info "Configuring Proxy ARP"

    sysctl -w net.ipv4.conf."$WAN_IFACE".proxy_arp=1
    sysctl -w net.ipv4.conf."$WIFI_IFACE".proxy_arp=1

    ip addr add "$LAN_IP/24" dev "$WAN_IFACE"
    ip addr add "$LAN_IP/24" dev "$WIFI_IFACE"

    backup_file /etc/dnsmasq.conf
    killall dnsmasq
    cat > "$DNSMASQ_CONF" << EOF
interface=$WIFI_IFACE
bind-interfaces
server=$LAN_DNS_SERVER
dhcp-range=$LAN_DHCP_START,$LAN_DHCP_END,255.255.255.0,12h
EOF

    log_info "Starting dnsmasq"
    dnsmasq -C "$DNSMASQ_CONF"

    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$WIFI_IFACE" -o "$WAN_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$WAN_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

    log_info "Proxy ARP configuration completed"
}

function setup_bridge {
    log_info "Configuring Bridge"

    BR_IFACE="br0"

    ip link add name "$BR_IFACE" type bridge

    ip link set dev "$WAN_IFACE" up
    ip link set dev "$WIFI_IFACE" up
    ip link set dev "$BR_IFACE" up

    ip link set dev "$WAN_IFACE" master "$BR_IFACE"
    ip link set dev "$WIFI_IFACE" master "$BR_IFACE"

    ip addr add "$LAN_IP/24" dev "$BR_IFACE"

    backup_file /etc/dnsmasq.conf
    killall dnsmasq
    cat > "$DNSMASQ_CONF" << EOF
interface=$BR_IFACE
bind-interfaces
server=$LAN_DNS_SERVER
dhcp-range=$LAN_DHCP_START,$LAN_DHCP_END,255.255.255.0,12h
EOF

    log_info "Starting dnsmasq"
    dnsmasq -C "$DNSMASQ_CONF"

    echo "bridge=$BR_IFACE" >> "$HOSTAPD_CONF"

    log_info "Bridge configuration completed"
}

setup_ap

trap cleanup EXIT

log_info "Access point is running. Press Ctrl+C to stop."

while true; do
    sleep 60
done

