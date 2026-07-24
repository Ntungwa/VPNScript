#!/bin/bash

# ---- Helper functions ----
is_number() {
    [[ $1 =~ ^[0-9]+$ ]]
}

# ---- Colors ----
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
NC='\033[0m'

# ---- Ensure we are root ----
if [ "$(whoami)" != "root" ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# ---- Install jq for JSON handling ----
if ! command -v jq &> /dev/null; then
    apt update && apt install -y jq
fi

# ---- State file for uninstall ----
STATE_FILE="/root/.ash_install_state"

# Initialize state file if missing
init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '[]' > "$STATE_FILE"
    fi
}

# Add a component record
add_state() {
    local name="$1"
    local install_dir="$2"
    local service="$3"
    local screen_session="$4"
    local ports="$5"
    local iptables_rules="$6"
    local sysctl_settings="$7"
    local notes="$8"

    # Build JSON object
    local new_entry=$(jq -n \
        --arg name "$name" \
        --arg dir "$install_dir" \
        --arg service "$service" \
        --arg screen "$screen_session" \
        --arg ports "$ports" \
        --arg iptables "$iptables_rules" \
        --arg sysctl "$sysctl_settings" \
        --arg notes "$notes" \
        '{name: $name, install_dir: $dir, systemd_service: $service, screen_session: $screen, ports: $ports, iptables_rules: $iptables, sysctl_settings: $sysctl, notes: $notes}')
    local tmp=$(mktemp)
    jq --argjson new "$new_entry" '. + [$new]' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Remove a component by name
remove_state_by_name() {
    local name="$1"
    local tmp=$(mktemp)
    jq --arg name "$name" 'map(select(.name != $name))' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ---- Uninstall functions ----
uninstall_component() {
    local name="$1"
    # Retrieve entry from state
    local entry=$(jq --arg name "$name" '.[] | select(.name == $name)' "$STATE_FILE")
    if [ -z "$entry" ]; then
        echo -e "${RED}Component '$name' not found in state.${NC}"
        return 1
    fi

    local dir=$(echo "$entry" | jq -r '.install_dir')
    local service=$(echo "$entry" | jq -r '.systemd_service')
    local screen_session=$(echo "$entry" | jq -r '.screen_session')
    local iptables_rules=$(echo "$entry" | jq -r '.iptables_rules')
    local sysctl_settings=$(echo "$entry" | jq -r '.sysctl_settings')
    local notes=$(echo "$entry" | jq -r '.notes')

    echo -e "${YELLOW}Uninstalling $name...${NC}"

    # Stop and disable systemd service
    if [ -n "$service" ] && systemctl list-unit-files | grep -q "^$service"; then
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        rm -f "/etc/systemd/system/$service"
        systemctl daemon-reload
        echo "  Removed systemd service $service"
    fi

    # Kill screen session if any
    if [ -n "$screen_session" ]; then
        screen -S "$screen_session" -X quit 2>/dev/null
        echo "  Killed screen session $screen_session"
    fi

    # Remove installation directory
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "  Removed directory $dir"
    fi

    # Remove iptables rules
    if [ -n "$iptables_rules" ] && [ "$iptables_rules" != "null" ]; then
        IFS=';' read -ra rules <<< "$iptables_rules"
        for rule in "${rules[@]}"; do
            # Convert -A to -D for deletion
            local del_rule=$(echo "$rule" | sed 's/-A /-D /')
            eval "$del_rule" 2>/dev/null && echo "  Removed iptables rule: $del_rule" || echo "  Warning: Could not remove rule: $del_rule"
        done
    fi

    # Warn about sysctl changes (do not revert automatically)
    if [ -n "$sysctl_settings" ] && [ "$sysctl_settings" != "null" ]; then
        echo -e "${YELLOW}  Note: The following sysctl settings were applied:${NC}"
        echo "    $sysctl_settings"
        echo "  Please review and revert if necessary."
    fi

    # Show notes (e.g., manual steps for DNS2TCP)
    if [ -n "$notes" ] && [ "$notes" != "null" ]; then
        echo -e "${YELLOW}  Manual steps required:${NC}"
        echo "    $notes"
    fi

    # Remove from state
    remove_state_by_name "$name"
    echo -e "${GREEN}Uninstall of $name completed.${NC}"
}

uninstall_menu() {
    init_state
    local count=$(jq '. | length' "$STATE_FILE")
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}No components are installed (state file empty).${NC}"
        return
    fi

    echo -e "${YELLOW}Installed components:${NC}"
    jq -r 'to_entries | .[] | "\(.key+1). \(.value.name) (ports: \(.value.ports), dir: \(.value.install_dir))"' "$STATE_FILE"
    echo ""
    echo -e "Select the number to uninstall, or '${GREEN}a${NC}' for all, or '${RED}q${NC}' to quit:"
    read -r choice

    case "$choice" in
        [0-9]*)
            local idx=$((choice-1))
            local name=$(jq -r ".[$idx].name" "$STATE_FILE")
            if [ -n "$name" ] && [ "$name" != "null" ]; then
                uninstall_component "$name"
            else
                echo -e "${RED}Invalid selection.${NC}"
            fi
            ;;
        a|A)
            for name in $(jq -r '.[].name' "$STATE_FILE"); do
                uninstall_component "$name"
            done
            echo -e "${GREEN}All components uninstalled.${NC}"
            ;;
        q|Q)
            echo "Returning to main menu."
            ;;
        *)
            echo -e "${RED}Invalid input.${NC}"
            ;;
    esac
}

# ---- Add custom banner to .bashrc ----
MARKER="### CUSTOM COLOR BLOCK ###"
TEXT_TO_ADD='
'"$MARKER"'
YELLOW='\''\033[1;33m'\''
RED='\''\033[1;31m'\''
CYAN='\''\033[1;36m'\''
GREEN='\''\033[1;32m'\''
NC='\''\033[0m'\''
echo ""
echo -e "$CYAN   A   $YELLOW SSS  $RED H   H"
echo -e "$CYAN  A A  $YELLOW S    $RED H   H"
echo -e "$CYAN AAAAA $YELLOW SSS  $RED HHHHH"
echo -e "$CYAN A   A $YELLOW     S$RED H   H"
echo -e "$CYAN A   A $YELLOW SSSS $RED H   H"
echo -e "$NC"
'"$MARKER"'
'
if ! grep -Fq "$MARKER" ~/.bashrc; then
    echo "$TEXT_TO_ADD" >> ~/.bashrc
fi

# ---- Main menu ----
cd /root
clear
echo -e "$CYAN   A   $YELLOW SSS  $RED H   H"
echo -e "$CYAN  A A  $YELLOW S    $RED H   H"
echo -e "$CYAN AAAAA $YELLOW SSS  $RED HHHHH"
echo -e "$CYAN A   A $YELLOW     S$RED H   H"
echo -e "$CYAN A   A $YELLOW SSSS $RED H   H"
echo ""
echo -e "$YELLOW
VPN Tunnel Installer by AhmedSCRIPT Hacker"
echo "Version : 4.8 (with Uninstall)"
echo -e "$NC
Select an option"
echo "1.  Install UDP Hysteria V1.3.5"
echo "2.  Install ASH WSS"
echo "3.  Install ASH HTTP + WS"
echo "4.  Install DNSTT, DoH and DoT"
echo "5.  Install VPS AGN (no longer available)"
echo "6.  Install DNS2TCP"
echo "7.  Install BadVPN UDPGW (port 7300)"
echo "8.  Install ASH SSL"
echo "9.  Install ASH SSH"
echo "10. Uninstall components"
echo "0.  Exit"

selected_option=-1
while [ $selected_option -lt 0 ] || [ $selected_option -gt 10 ]; do
    echo -e "$YELLOW"
    echo "Select a number from 0 to 10:"
    echo -e "$NC"
    read input

    if [[ $input =~ ^[0-9]+$ ]]; then
        selected_option=$input
    else
        echo -e "$YELLOW"
        echo "Invalid input. Please enter a valid number."
        echo -e "$NC"
    fi
done
clear

# Initialize state file for any installation
init_state

case $selected_option in
    1)
        echo -e "$YELLOW"
        echo "Installing UDP Hysteria V1.3.5 ..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install wget nano net-tools openssl iptables-persistent screen lsof
        rm -rf hy
        mkdir hy
        cd hy
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/ashhysteria-linux-amd64
        chmod 755 ashhysteria-linux-amd64
        openssl ecparam -genkey -name prime256v1 -out ca.key
        openssl req -new -x509 -days 36500 -key ca.key -out ca.crt -subj "/CN=bing.com"
        while true; do
            echo -e "$YELLOW"
            read -p "Obfs : " obfs
            echo -e "$NC"
            if [ ! -z "$obfs" ]; then
            break
            fi
        done
        while true; do
            echo -e "$YELLOW"
            read -p "Auth Str : " auth_str
            echo -e "$NC"
            if [ ! -z "$auth_str" ]; then
            break
            fi
        done
        while true; do
            echo -e "$YELLOW"
            read -p "Remote UDP Port : " remote_udp_port
            echo -e "$NC"
            if is_number "$remote_udp_port" && [ "$remote_udp_port" -ge 1 ] && [ "$remote_udp_port" -le 65534 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65534."
                echo -e "$NC"
            fi
        done
        file_path="/root/hy/config.json"
        json_content='{"listen":":'"$remote_udp_port"'","protocol":"udp","cert":"/root/hy/ca.crt","key":"/root/hy/ca.key","up":"100 Mbps","up_mbps":100,"down":"100 Mbps","down_mbps":100,"disable_udp":false,"obfs":"'"$obfs"'","auth_str":"'"$auth_str"'"}'
        echo "$json_content" > "$file_path"
        if [ ! -e "$file_path" ]; then
            echo -e "$YELLOW"
            echo "Error: Unable to save the config.json file"
            echo -e "$NC"
            exit 1
        fi
        sudo debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
        sudo debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"

        echo -e "$YELLOW"
        read -p "Bind multiple UDP Ports? (y/n): " bind
        echo -e "$NC"
        iptables_rules=""
        if [ "$bind" = "y" ]; then
            while true; do
                echo -e "$YELLOW"
                read -p "Binding UDP Ports : from port : " first_number
                echo -e "$NC"
                if is_number "$first_number" && [ "$first_number" -ge 1 ] && [ "$first_number" -le 65534 ]; then
                  break
                else
                    echo -e "$YELLOW"
                    echo "Invalid input. Please enter a valid number between 1 and 65534."
                    echo -e "$NC"
                fi
            done
            while true; do
                echo -e "$YELLOW"
                read -p "Binding UDP Ports : from port : $first_number to port : " second_number
                echo -e "$NC"
                if is_number "$second_number" && [ "$second_number" -gt "$first_number" ] && [ "$second_number" -lt 65536 ]; then
                    break
                else
                    echo -e "$YELLOW"
                    echo "Invalid input. Please enter a valid number greater than $first_number and less than 65536."
                    echo -e "$NC"
                fi
            done
            # Remove old rules
            iptables -t nat -L --line-numbers | awk -v var="$first_number:$second_number" '$0 ~ var {print $1}' | tac | xargs -r -I {} iptables -t nat -D PREROUTING {}
            ip6tables -t nat -L --line-numbers | awk -v var="$first_number:$second_number" '$0 ~ var {print $1}' | tac | xargs -r -I {} ip6tables -t nat -D PREROUTING {}
        
            # Add new rules
            local iface=$(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1)
            iptables -t nat -A PREROUTING -i "$iface" -p udp --dport "$first_number":"$second_number" -j DNAT --to-destination :$remote_udp_port
            ip6tables -t nat -A PREROUTING -i "$iface" -p udp --dport "$first_number":"$second_number" -j DNAT --to-destination :$remote_udp_port
            iptables_rules="iptables -t nat -A PREROUTING -i $iface -p udp --dport $first_number:$second_number -j DNAT --to-destination :$remote_udp_port; ip6tables -t nat -A PREROUTING -i $iface -p udp --dport $first_number:$second_number -j DNAT --to-destination :$remote_udp_port"
        fi

        # ---- Apply full sysctl tuning (like ZiVPN) ----
        local iface=$(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1)
        cat > /etc/sysctl.d/99-hysteria.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.optmem_max=65536
net.core.somaxconn=65535
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_fastopen=3
fs.file-max=1000000
net.core.netdev_max_backlog=16384
net.ipv4.udp_mem=65536 131072 262144
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.$iface.rp_filter=0
EOF
        sysctl --system
        # Record sysctl settings for uninstall warning
        sysctl_setting="net.core.default_qdisc=fq; net.ipv4.tcp_congestion_control=bbr; net.ipv4.ip_forward=1; net.core.rmem_max=16777216; net.core.wmem_max=16777216; net.core.rmem_default=16777216; net.core.wmem_default=16777216; net.core.optmem_max=65536; net.core.somaxconn=65535; net.ipv4.tcp_rmem=4096 87380 16777216; net.ipv4.tcp_wmem=4096 65536 16777216; net.ipv4.tcp_fastopen=3; fs.file-max=1000000; net.core.netdev_max_backlog=16384; net.ipv4.udp_mem=65536 131072 262144; net.ipv4.udp_rmem_min=8192; net.ipv4.udp_wmem_min=8192; net.ipv4.conf.all.rp_filter=0; net.ipv4.conf.$iface.rp_filter=0"
        # Save iptables
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6

        # Run mode
        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="hy.service"
        if [ "$bind" = "b" ]; then
            screen -dmS hy ./ashhysteria-linux-amd64 server --log-level 0
            screen_session="hy"
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize UDP Hysteria V1 Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/hy/ashhysteria-linux-amd64 server -c /root/hy/config.json --log-level 0
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/hy.service
            systemctl start hy
            systemctl enable hy
        fi
        lsof -i :"$remote_udp_port"
        echo "UDP Hysteria V1.3.5 installed successfully, please check the logs above"
        echo "IP Address :"
        curl ipv4.icanhazip.com
        echo "Obfs : '"$obfs"'"
        echo "auth str : '"$auth_str"'"

        # Record state (sysctl settings included)
        add_state "hysteria" "/root/hy" "$service_name" "$screen_session" "$remote_udp_port" "$iptables_rules" "$sysctl_setting" ""
        exit 1
        ;;
    2)
        echo -e "$YELLOW"
        echo "Installing ASH WSS..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install openssl lsof screen
        while true; do
            echo -e "$YELLOW"
            read -p "Remote WSS Port : " wss_port
            echo -e "$NC"
            if is_number "$wss_port" && [ "$wss_port" -ge 1 ] && [ "$wss_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        while true; do
            echo -e "$YELLOW"
            read -p "Target TCP Port : " target_port
            echo -e "$NC"
            if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        rm -rf ashwss
        mkdir ashwss
        cd ashwss
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/ashwebsocketsni-linux-amd64
        chmod 755 ashwebsocketsni-linux-amd64
        openssl genrsa -out stunnel.key 2048
        openssl req -new -key stunnel.key -x509 -days 1000 -out stunnel.crt
        cat stunnel.crt stunnel.key > stunnel.pem
        rm -rf stunnel.crt

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="ashwss.service"
        if [ "$bind" = "b" ]; then
            screen -dmS ashwss ./ashwebsocketsni-linux-amd64 -listen :$wss_port -forward 127.0.0.1:$target_port -private_key stunnel.pem -public_key stunnel.key
            screen_session="ashwss"
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize ASH WSS Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/ashwss/ashwebsocketsni-linux-amd64 -listen :$wss_port -forward 127.0.0.1:$target_port -private_key /root/ashwss/stunnel.pem -public_key /root/ashwss/stunnel.key
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/ashwss.service
            systemctl start ashwss
            systemctl enable ashwss
        fi
        lsof -i :"$wss_port"
        echo -e "$YELLOW"
        echo "ASH WSS Installed Successfully"
        echo -e "$NC"

        add_state "ashwss" "/root/ashwss" "$service_name" "$screen_session" "$wss_port" "" "" ""
        exit 1
        ;;
    3)
        echo -e "$YELLOW"
        echo "Installing ASH HTTP + WS..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install iptables-persistent wget screen lsof
        while true; do
            echo -e "$YELLOW"
            read -p "Remote HTTP Port : " http_port
            echo -e "$NC"
            if is_number "$http_port" && [ "$http_port" -ge 1 ] && [ "$http_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        while true; do
            echo -e "$YELLOW"
            read -p "Target HTTP Port : " target_port
            echo -e "$NC"
            if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        echo -e "$YELLOW"
        read -p "Bind multiple TCP Ports? (y/n): " bind
        echo -e "$NC"
        iptables_rules=""
        if [ "$bind" = "y" ]; then
            while true; do
            echo -e "$YELLOW"
            read -p "Binding TCP Ports : from port : " first_number
            echo -e "$NC"
                if is_number "$first_number" && [ "$first_number" -ge 1 ] && [ "$first_number" -le 65534 ]; then
                    break
                else
                    echo -e "$YELLOW"
                    echo "Invalid input. Please enter a valid number between 1 and 65534."
                    echo -e "$NC"
                fi
            done
            while true; do
                echo -e "$YELLOW"
                read -p "Binding TCP Ports : from port : $first_number to port : " second_number
                echo -e "$NC"
                if is_number "$second_number" && [ "$second_number" -gt "$first_number" ] && [ "$second_number" -lt 65536 ]; then
                    break
                else
                    echo -e "$YELLOW"
                    echo "Invalid input. Please enter a valid number greater than $first_number and less than 65536."
                    echo -e "$NC"
                fi
            done
            iptables -t nat -A PREROUTING -p tcp --dport "$first_number":"$second_number" -j REDIRECT --to-port "$http_port"
            iptables-save > /etc/iptables/rules.v4
            iptables_rules="iptables -t nat -A PREROUTING -p tcp --dport $first_number:$second_number -j REDIRECT --to-port $http_port"
        fi
        rm -rf ashhttp
        mkdir ashhttp
        cd ashhttp
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/ashhttpproxy-linux-amd64
        chmod 755 ashhttpproxy-linux-amd64

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="ashhttp.service"
        if [ "$bind" = "b" ]; then
            screen -dmS ashhttp ./ashhttpproxy-linux-amd64 -listen :$http_port -forward 127.0.0.1:$target_port
            screen_session="ashhttp"
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize ASH HTTP Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/ashhttp/ashhttpproxy-linux-amd64 -listen :$http_port -forward 127.0.0.1:$target_port
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/ashhttp.service
            systemctl start ashhttp
            systemctl enable ashhttp
        fi

        lsof -i :"$http_port"
        echo -e "$YELLOW"
        echo "ASH HTTP + WS installed successfully"
        echo -e "$NC"

        add_state "ashhttp" "/root/ashhttp" "$service_name" "$screen_session" "$http_port" "$iptables_rules" "" ""
        exit 1
        ;;
    4)
        echo -e "$YELLOW"
        echo "Installing DNSTT,DoH and DoT ..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install iptables-persistent wget screen lsof
        rm -rf dnstt
        mkdir dnstt
        cd dnstt
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/dnstt-server
        chmod 755 dnstt-server
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/server.key
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/server.pub
        echo -e "$YELLOW"
        cat server.pub
        read -p "Copy the pubkey above and press Enter when done"
        read -p "Enter your Nameserver : " ns
        iptables -I INPUT -p udp --dport 5300 -j ACCEPT
        iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
        iptables-save > /etc/iptables/rules.v4
        iptables_rules="iptables -I INPUT -p udp --dport 5300 -j ACCEPT; iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300"

        while true; do
            echo -e "$YELLOW"
            read -p "Target TCP Port : " target_port
            echo -e "$NC"
            if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="dnstt.service"
        if [ "$bind" = "b" ]; then
            screen -dmS slowdns ./dnstt-server -udp :5300 -privkey-file server.key $ns 127.0.0.1:$target_port
            screen_session="slowdns"
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize DNSTT Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/dnstt/dnstt-server -udp :5300 -privkey-file /root/dnstt/server.key $ns 127.0.0.1:$target_port
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/dnstt.service
            systemctl start dnstt
            systemctl enable dnstt
        fi

        lsof -i :5300
        echo -e "DNSTT installation completed"
        echo -e "$NC"

        add_state "dnstt" "/root/dnstt" "$service_name" "$screen_session" "5300" "$iptables_rules" "" ""
        exit 1
        ;;
    5)
        echo -e "$YELLOW"
        echo "No longer available"
        echo -e "$NC"
        exit 1
        # The original had code that would run; we skip state
        ;;
    6)
        echo -e "$YELLOW"
        echo -e "Before you continue, make sure that :"
        echo -e "- No program uses UDP Port 53"
        echo -e "- DNSTT is not running"
        echo -e "- iptables doesn't forward the port 53 to another port"
        echo -e "$NC"
        read
        apt -y update && apt -y upgrade
        apt -y install screen lsof dns2tcp nano
        echo -e "$YELLOW"
        read -p "In this step, you will uncomment DNS and write DNS=1.1.1.1 and uncomment DNSStubListener and write DNSStubListener=no"
        echo -e "$NC"
        nano /etc/systemd/resolved.conf
        echo -e "$YELLOW"
        read -p "by tapping 'Enter', you make sure that you have uncomment DNS=1.1.1.1 and DNSStubListener=no"
        echo -e "$NC"
        systemctl restart systemd-resolved
        mkdir dns2tcp
        cd dns2tcp
        mkdir /var/empty
        mkdir /var/empty/dns2tcp
        echo -e "$YELLOW"
        read -p "Your Nameserver: " nameserver
        read -p "Your key: " key
        echo -e "$NC"
        while true; do
            echo -e "$YELLOW"
            read -p "Target TCP Port : " target_port
            echo -e "$NC"
            if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        file_path="/root/dns2tcp/dns2tcpdrc"
        json_content=$(cat <<EOF
listen = 0.0.0.0
port = 53
user = ashtunnel
chroot = /var/empty/dns2tcp/
domain = $nameserver
key = $key
resources = ssh:127.0.0.1:$target_port
EOF
)
        echo "$json_content" > "$file_path"

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="dns2tcp.service"
        if [ "$bind" = "b" ]; then
            dns2tcpd -d 1 -f dns2tcpdrc &
            screen_session="dns2tcp"  # not using screen, but we'll store as marker
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize DNS2TCP Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/usr/bin/dns2tcpd -d 1 -F -f /root/dns2tcp/dns2tcpdrc
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/dns2tcp.service
            systemctl start dns2tcp
            systemctl enable dns2tcp
        fi
        echo -e "$YELLOW"
        read -p "in the next step, add nameserver 1.1.1.1 to the coming file if there is only nameserver 127.0.0.1 or nameserver 127.0.0.53"
        echo -e "$NC"
        nano /etc/resolv.conf
        echo -e "$YELLOW"
        read -p "by tapping 'Enter', you make sure that you have added nameserver 1.1.1.1"
        echo -e "$YELLOW"
        lsof -i :53
        echo "DNS2TCP server installed sucessfully"
        echo -e "$NC"

        # Record state with notes for manual revert
        notes="You modified /etc/systemd/resolved.conf (set DNS=1.1.1.1 and DNSStubListener=no) and /etc/resolv.conf (added 1.1.1.1). Please revert these files manually if you uninstall DNS2TCP."
        add_state "dns2tcp" "/root/dns2tcp" "$service_name" "$screen_session" "53" "" "" "$notes"
        # Do not exit; script continues (original didn't have exit)
        ;;
    7)
        echo -e "$YELLOW"
        echo "Installing BadVPN UDPGW (compiled from source)..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install cmake build-essential git lsof screen

        # Remove old badvpn directory if exists
        rm -rf /root/badvpn
        mkdir -p /root/badvpn

        # Clone and build badvpn from source
        cd /root
        git clone --depth 1 https://github.com/ambrop72/badvpn.git /root/badvpn-src
        cd /root/badvpn-src
        mkdir -p build
        cd build
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
        make -j$(nproc)
        cp udpgw/badvpn-udpgw /root/badvpn/badvpn-udpgw
        chmod +x /root/badvpn/badvpn-udpgw

        # Clean up source
        cd /root
        rm -rf /root/badvpn-src

        # Create systemd service with correct flags (max-connections-for-client 50)
        cat > /etc/systemd/system/badvpn.service <<-EOF
[Unit]
Description=Daemonize BadVPN UDPGW Server
Wants=network.target
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/badvpn/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 50
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl start badvpn
        systemctl enable badvpn

        lsof -i :7300
        echo -e "$YELLOW"
        echo "BadVPN UDPGW Installed Successfully (compiled from source, max-connections=50)"
        echo -e "$NC"

        add_state "badvpn" "/root/badvpn" "badvpn.service" "" "7300" "" "" ""
        exit 1
        ;;
    8)
        echo -e "$YELLOW"
        echo "Installing ASH SSL..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install openssl lsof screen
        while true; do
            echo -e "$YELLOW"
            read -p "Remote SSL Port : " ssl_port
            echo -e "$NC"
            if is_number "$ssl_port" && [ "$ssl_port" -ge 1 ] && [ "$ssl_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        while true; do
            echo -e "$YELLOW"
            read -p "Target TCP Port : " target_port
            echo -e "$NC"
            if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        rm -rf ashssl
        mkdir ashssl
        cd ashssl
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/ashsslproxy-linux-amd64
        chmod 755 ashsslproxy-linux-amd64
        openssl genrsa -out stunnel.key 2048
        openssl req -new -key stunnel.key -x509 -days 1000 -out stunnel.crt
        cat stunnel.crt stunnel.key > stunnel.pem
        rm -rf stunnel.crt

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="ashssl.service"
        if [ "$bind" = "b" ]; then
            screen -dmS ashssl ./ashsslproxy-linux-amd64 -listen :$ssl_port -forward 127.0.0.1:$target_port -private_key stunnel.pem -public_key stunnel.key
            screen_session="ashssl"
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize ASH SSL Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/ashssl/ashsslproxy-linux-amd64 -listen :$ssl_port -forward 127.0.0.1:$target_port -private_key /root/ashssl/stunnel.pem -public_key /root/ashssl/stunnel.key
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/ashssl.service
            systemctl start ashssl
            systemctl enable ashssl
        fi
        lsof -i :"$ssl_port"
        echo -e "$YELLOW"
        echo "ASH SSL Installed Successfully"
        echo -e "$NC"

        add_state "ashssl" "/root/ashssl" "$service_name" "$screen_session" "$ssl_port" "" "" ""
        exit 1
        ;;
    9)
        echo -e "$YELLOW"
        echo "[Warning] this version of SSH is only for tunneling, it has anti torrent features,"
        echo "it doesn't come with shell environment support, so do NOT ever replace it with your"
        echo "current SSH and use it only for tunneling, otherwise you will lose access for your shell."
        read -p "Press enter to accept and continue"
        echo "Installing ASH SSH..."
        echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install lsof screen
        while true; do
            echo -e "$YELLOW"
            read -p "Remote SSH Port : " ssh_port
            echo -e "$NC"
            if is_number "$ssh_port" && [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done
        rm -rf ashssh
        mkdir ashssh
        cd ashssh
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/ashssh-linux-amd64
        chmod 755 ashssh-linux-amd64

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        screen_session=""
        service_name="ashssh.service"
        if [ "$bind" = "b" ]; then
            screen -dmS ashssh ./ashssh-linux-amd64 -listen :$ssh_port -hostkey /etc/ssh/ssh_host_rsa_key
            screen_session="ashssh"
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize ASH SSH Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/ashssh/ashssh-linux-amd64 -listen :$ssh_port -hostkey /etc/ssh/ssh_host_rsa_key
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/ashssh.service
            systemctl start ashssh
            systemctl enable ashssh
        fi
        lsof -i :"$ssh_port"
        echo -e "$YELLOW"
        echo "ASH SSH Installed Successfully"
        echo -e "$NC"

        add_state "ashssh" "/root/ashssh" "$service_name" "$screen_session" "$ssh_port" "" "" ""
        exit 1
        ;;
    10)
        uninstall_menu
        ;;
    0)
        echo -e "$YELLOW"
        echo "Good Bye"
        echo -e "$NC"
        exit 0
        ;;
esac