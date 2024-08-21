#!/bin/bash

WG_MONKEY_DIR="/opt/wg-monkey"
WG_MONKEY_BIN="/usr/local/bin/wg-monkey"

create_files() {
    echo "Creating necessary directories and files..."

    # Create the main directory structure
    mkdir -p "$WG_MONKEY_DIR/wg-modes"
    mkdir -p "$WG_MONKEY_DIR/deviceconfigs/wg0"
    mkdir -p "$WG_MONKEY_DIR/backups"

    # Create modify_config.py
    cat << EOF1 > "$WG_MONKEY_DIR/modify_config.py"
import configparser
import sys

def modify_config(source_file, dest_file):
    config = configparser.ConfigParser()
    config.optionxform = str  # Preserve case of the options
    config.read(source_file)

    # Assume 'myconfig' is the section to be removed
    if 'myconfig' in config.sections():
        config.remove_section('myconfig')

    with open(dest_file, 'w') as configfile:
        config.write(configfile)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python modify_config.py source_file dest_file")
        sys.exit(1)
    modify_config(sys.argv[1], sys.argv[2])
EOF1

    # Create wg-monkey.sh (the main script)
    cat << EOF2 > "$WG_MONKEY_DIR/wg-monkey.sh"
#!/bin/bash

# Configuration

WG_BASE_DIR="/opt/wg-monkey"
WG_MODES_DIR="\${WG_BASE_DIR}/wg-modes"
DEVICE_CONFIGS_DIR="\${WG_BASE_DIR}/deviceconfigs"
BACKUP_DIR="\${WG_BASE_DIR}/backups"

# Function to list available modes
list_modes() {
    echo "Available WireGuard Modes:"
    echo
    for config_file in \${WG_MODES_DIR}/*; do
        local mode_file=\$(basename \$config_file)
        local mode_name=\$(grep 'name=' \$config_file | cut -d '=' -f2 | xargs)
        local description=\$(grep 'description=' \$config_file | cut -d '=' -f2 | xargs)
        printf "%s: %s\n" "\$mode_name" "\$description"
        printf "\tMode file: %s\n\n" "\$mode_file"
    done
}

# Function to remove blackhole from the route table
remove_blackhole() {
    echo "Checking for blackhole route..."
    if ip route | grep -q 'blackhole default'; then
        echo "Blackhole route found. Removing..."
        ip route del blackhole default
        echo "Blackhole route removed."
    else
        echo "No blackhole route found. Nothing to remove."
    fi
}

# Function to switch modes
switch_mode() {
    local interface=\$1
    local mode_name=\$2
    local creds_file="\${DEVICE_CONFIGS_DIR}/\${interface}/\${interface}.creds"
    local config_file
    local found_mode=0
    local temp_config="/tmp/\${interface}_temp.conf"
    local final_config="/tmp/\${interface}_final.conf"
    local actual_config="/etc/wireguard/\${interface}.conf"

    echo "Looking for mode '\$mode_name' in \$WG_MODES_DIR"

    # Find and prepare the configuration file
    for file in "\${WG_MODES_DIR}"/*; do
        if grep -q "name=\$mode_name" "\$file"; then
            config_file=\$file
            found_mode=1
            break
        fi
    done

    if [[ \$found_mode -eq 0 ]]; then
        echo "Error: Mode '\$mode_name' not found."
        exit 1
    fi

    echo "Found mode '\$mode_name' in file \$config_file"

    # Load credentials
    if [ -f "\$creds_file" ]; then
        source "\$creds_file"
    else
        echo "Credentials file not found at \$creds_file"
        exit 1
    fi

    # Replace placeholders in the temp config file
    cp "\$config_file" "\$temp_config"
    sed -i "s|<privatekey>|\$PRIVATE_KEY|g" "\$temp_config"
    sed -i "s|<publickey>|\$PUBLIC_KEY|g" "\$temp_config"
    sed -i "s|<peer-endpoint>|\$PEER_ENDPOINT|g" "\$temp_config"
    sed -i "s|<address>|\$ADDRESS|g" "\$temp_config"
    sed -i "s|<fwmark>|\$FWMARK|g" "\$temp_config"
    sed -i "s|<table>|\$TABLE|g" "\$temp_config"

    # Modify the configuration using a Python script
    python3 "\${WG_BASE_DIR}/modify_config.py" "\$temp_config" "\$final_config"

    # Ensure no spaces around equals signs in the final configuration
    sed -i 's/ \?= \?/=/g' "\$final_config"

    # Back up existing configuration if it exists
    if [[ -f "\$actual_config" ]]; then
        local backup_file="\${BACKUP_DIR}/\${interface}/\${interface}_\$(date +%Y-%m-%d-%H%M%S).conf"
        mkdir -p "\${BACKUP_DIR}/\${interface}"
        cp "\$actual_config" "\$backup_file"
        echo "Backup of existing configuration saved to \$backup_file"
    fi

    # Bring down the interface safely
    if ip link show \$interface > /dev/null 2>&1; then
        wg-quick down \$interface
    fi

    remove_blackhole

    # Apply the final configuration
    cp "\$final_config" "\$actual_config"
    echo "New configuration applied from \$final_config to \$actual_config"

    # Apply the new configuration using wg-quick
    wg-quick up \$actual_config

    echo "\$interface has been configured in \$mode_name mode."
}

# Function to display usage information
display_usage() {
    cat << EOF
Usage: \$0 <command> [options]

Commands:
  list modes                       List all available WireGuard modes
  switch <interface> <mode>        Switch to a specific mode for the given interface
  remove_blackhole                 Remove the blackhole route from the routing table

Examples:
  \$0 list modes
  \$0 switch wg0 lankillswitch
  \$0 remove_blackhole

EOF
}

# Main script logic
if [[ \$# -lt 1 ]]; then
    display_usage
    exit 1
fi

case \$1 in
    list)
        if [[ \$2 == "modes" ]]; then
            list_modes
        else
            display_usage
        fi
        ;;
    switch)
        if [[ -n \$2 && -n \$3 ]]; then
            switch_mode \$2 \$3
        else
            display_usage
        fi
        ;;
    remove_blackhole)
        remove_blackhole
        ;;
    *)
        display_usage
        ;;
esac
EOF2

    chmod +x "$WG_MONKEY_DIR/wg-monkey.sh"

    # Create sample configuration files
    cat << EOF3 > "$WG_MONKEY_DIR/wg-modes/lankillswitch.conf"
[myconfig]
name=lankillswitch
description=A kill switch enabled wireguard connection that allows access to local network devices, drops pings.

[Interface]
PrivateKey=<privatekey>
Address=<address>
FwMark=<fwmark>
Table=<table>

PostUp=ip rule show | grep -q 'not fwmark <fwmark> table <table>' || ip rule add not fwmark <fwmark> table <table>; ip rule show | grep -q 'table main suppress_prefixlength 0' || ip rule add table main suppress_prefixlength 0; ip route | grep -q 'blackhole default' && ip route del blackhole 0.0.0.0/0 || true;

PostDown=ip rule show | grep -q 'not fwmark <fwmark> table <table>' && ip rule del not fwmark <fwmark> table <table>; ip rule show | grep -q 'table main suppress_prefixlength 0' && ip rule del table main suppress_prefixlength 0; ip route | grep -q 'blackhole default' || ip route add blackhole 0.0.0.0/0 || true;

[Peer]
PublicKey=<publickey>
Endpoint=<peer-endpoint>
AllowedIPs=0.0.0.0/0
PersistentKeepalive=25
EOF3

    cat << EOF4 > "$WG_MONKEY_DIR/wg-modes/totalkillswitch.conf"
[myconfig]
name=totalkillswitch
description=A kill switch enabled wireguard connection that blocks access to local network devices, drops pings.

[Interface]
PrivateKey=<privatekey>
Address=<address>
FwMark=<fwmark>
Table=<table>

PostUp=ip rule add not fwmark <fwmark> table <table>; ip rule add table main suppress_prefixlength 0; ip route | grep -q 'blackhole default' && ip route del blackhole 0.0.0.0/0 || true; iptables -A OUTPUT -d 192.168.0.0/16 -j DROP; iptables -A OUTPUT -d 172.16.0.0/12 -j DROP; iptables -A OUTPUT -d 10.0.0.0/8 -j DROP; iptables -A INPUT -p icmp --icmp-type echo-request -j DROP


PreDown=ip rule del not fwmark <fwmark> table <table>; ip rule del table main suppress_prefixlength 0; ip route | grep -q 'blackhole default' || ip route add blackhole 0.0.0.0/0 || true; iptables -D OUTPUT -d 192.168.0.0/16 -j DROP; iptables -D OUTPUT -d 172.16.0.0/12 -j DROP; iptables -D OUTPUT -d 10.0.0.0/8 -j DROP; iptables -D INPUT -p icmp --icmp-type echo-request -j DROP

[Peer]
PublicKey=<publickey>
Endpoint=<peer-endpoint>
AllowedIPs=0.0.0.0/0
PersistentKeepalive=25
EOF4

    cat << EOF5 > "$WG_MONKEY_DIR/wg-modes/wgstandard.conf"
[myconfig]
name=wgstandard
description=A standard wireguard connection (NO KILLSWITCH) that allows access to local network devices.
[Interface]
PrivateKey=<privatekey>
Address=<address>
PostUp=ip route del 192.168.0.0/24 dev wg0; ip route del 10.0.0.0/8 dev wg0; ip route del 172.16.0.0/12 dev wg0

[Peer]
PublicKey=<publickey>
Endpoint=<peer-endpoint>
AllowedIPs=0.0.0.0/0, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/24
PersistentKeepalive=25
EOF5

    # Create example wg0.creds file
    cat << EOF6 > "$WG_MONKEY_DIR/deviceconfigs/wg0/wg0.creds"
PUBLIC_KEY="example public key"
PEER_ENDPOINT="example peer endpoint"
PRIVATE_KEY="example private key"
ADDRESS="example address"
FWMARK="example fwmark"
TABLE="example table"
EOF6

    echo "Files created successfully."
}

install_wg_monkey() {
    echo "Installing wg-monkey..."

    # Create necessary directories and files
    create_files

    # Create a symbolic link to make wg-monkey accessible from anywhere
    ln -sf "$WG_MONKEY_DIR/wg-monkey.sh" "$WG_MONKEY_BIN"

    echo "wg-monkey installed successfully. You can run it using the command 'wg-monkey'."
}

uninstall_wg_monkey() {
    local full_uninstall=$1

    echo "Uninstalling wg-monkey..."

    # Remove the symbolic link
    if [ -f "$WG_MONKEY_BIN" ]; then
        rm "$WG_MONKEY_BIN"
        echo "Removed symbolic link $WG_MONKEY_BIN."
    fi

    if [ "$full_uninstall" = "full" ]; then  # Use a single '=' for string comparison
        # Remove the entire wg-monkey directory, including deviceconfigs
        rm -rf "$WG_MONKEY_DIR"
        echo "Full uninstallation complete. Removed $WG_MONKEY_DIR and all its contents."
    else
        # Remove all files and folders except the deviceconfigs directory
        if [ -d "$WG_MONKEY_DIR" ]; then
            find "$WG_MONKEY_DIR" -mindepth 1 -maxdepth 1 ! -name "deviceconfigs" -exec rm -rf {} +
            echo "Uninstallation complete. Retained $WG_MONKEY_DIR/deviceconfigs directory."
        fi
    fi
}



display_usage() {
    cat << EOF7
Usage: $0 <command>

Commands:
  install                 Install wg-monkey
  uninstall               Uninstall wg-monkey but keep the deviceconfigs directory
  uninstall full          Uninstall wg-monkey and remove everything including deviceconfigs directory

EOF7
}

# Main script logic for the installer
if [[ $# -lt 1 ]]; then
    display_usage
    exit 1
fi

# Ensure this part is correct in the main logic
case $1 in
    install)
        install_wg_monkey
        ;;
    uninstall)
        if [ "$2" == "full" ]; then
            uninstall_wg_monkey "full"
        else
            uninstall_wg_monkey
        fi
        ;;
    *)
        display_usage
        ;;
esac



