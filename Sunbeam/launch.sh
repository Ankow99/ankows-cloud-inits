#!/bin/bash

set +e

# --- Configuration & Smart SSH Key Detection ---
if [ -f ~/.ssh/id_ed25519 ]; then
    SSH_ID=~/.ssh/id_ed25519
elif [ -f ~/.ssh/id_rsa ]; then
    SSH_ID=~/.ssh/id_rsa
else
    SSH_ID=~/.ssh/id_ed25519 # Fallback default
fi

VM_NAME="sunrepro"
IMAGE="ubuntu:24.04"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CLOUD_INIT="$SCRIPT_DIR/cloud-init/cloud-config.yaml"

CURSOR_TOP='\033[H'
CLEAR_REST='\033[J'
CLR_EOL=$'\033[K'

NO_NEST=false
ACCEPT_DEFAULTS=false

# Array to hold dynamic LXD and Jinja flags
LXC_OPTIONAL_ARGS=()

# Generate the random bridges: specific prefix + 8 hex chars
RANDOM_MAAS_BRIDGE="mbr-$(openssl rand -hex 4)"
RANDOM_NEU_BRIDGE="nbr-$(openssl rand -hex 4)"

MAX_WAIT=120 # Maximum wait time in minutes for loops

# --- Colors ---
# Check if stderr is a TTY
if [ -t 2 ]; then
    BRED='\033[1;31m'
    BYELLOW='\033[1;33m'
    NC='\033[0m'
else
    BRED=''
    BYELLOW=''
    NC=''
fi

# --- Split combined short flags (e.g. -nd -> -n -d) ---
parsed_args=()
for arg in "$@"; do
    if [[ "$arg" =~ ^-[a-zA-Z]{2,}$ ]]; then
        for (( i=1; i<${#arg}; i++ )); do
            parsed_args+=("-${arg:$i:1}")
        done
    else
        parsed_args+=("$arg")
    fi
done
set -- "${parsed_args[@]}"

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--accept-defaults)
            echo -e "${BYELLOW}-> Accepting all default template values ${NC}"
            echo ""
            ACCEPT_DEFAULTS=true
            shift 1
            ;;
        -n|--nn)
            NO_NEST=true
            shift 1
            ;;
        -d|--deb)
            echo -e "${BYELLOW}-> Using deb MAAS packages instead of snap ${NC}"
            echo ""
            LXC_OPTIONAL_ARGS+=("-c" "user.maas_snap=false")
            shift 1
            ;;
        --lp)
            echo -e "${BYELLOW}-> Importing SSH keys from Launchpad${NC} 'lp:$2'"
            echo ""
            LXC_OPTIONAL_ARGS+=("-c" "user.ssh_import_id=lp:$2")
            shift 2
            ;;
        -*)
            echo -e "${BRED}Error: Unknown flag '$1' ${NC}"
            exit 1
            ;;
        *)
            VM_NAME="$1"
            shift 1
            ;;
    esac
done

if [ "$NO_NEST" = true ]; then
    echo -e "${BYELLOW}-> Using non nested LXD architecture. ${NC}"
    echo ""
    LXC_OPTIONAL_ARGS+=("-c" "user.nested_lxd=false")
else
    echo -e "${BYELLOW}-> Using default nested LXD architecture. ${NC}"
    echo ""
    LXC_OPTIONAL_ARGS+=("-c" "user.nested_lxd=true")
fi

# Check for cloud-init file
if [ ! -f "$CLOUD_INIT" ]; then
    echo -e "${BRED}Error: $CLOUD_INIT not found! ${NC}"
    exit 1
fi

# Check for dependencies
for cmd in jq openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${BRED}Error: '$cmd' is not installed. Please install it.${NC}"
        exit 1
    fi
done

# Check VM name
if [[ ! "$VM_NAME" =~ ^[a-z0-9][a-z0-9\-]*[a-z0-9]$ ]]; then
    echo -e "${BRED}Error: Invalid VM name '$VM_NAME'.${NC}"
    echo "LXD instance names must be lowercase alphanumeric and hyphens only (e.g., 'repro-sunbeam-1')."
    exit 1
fi

# Auto-inject local SSH public key
if [ -f "${SSH_ID}.pub" ]; then
    echo -e "${BYELLOW}-> Auto-injecting local SSH public key:${NC} ${SSH_ID}.pub"
    echo ""
    PUB_KEY=$(cat "${SSH_ID}.pub")
    LXC_OPTIONAL_ARGS+=("-c" "user.ssh_key=$PUB_KEY")
fi

# Abort if there's neither a local key nor a Launchpad ID
if [[ ! " ${LXC_OPTIONAL_ARGS[*]} " == *"user.ssh_key"* ]] && [[ ! " ${LXC_OPTIONAL_ARGS[*]} " == *"user.ssh_import_id"* ]]; then
    echo -e "${BRED}Warning: No SSH keys found (${NC}${SSH_ID}.pub${BRED}) and no Launchpad ID provided!${NC}"
    echo ""
    exit 1
fi

# Define SSH options dynamically based on key existence
if [ -f "$SSH_ID" ]; then
    SSH_OPTS=(-i "$SSH_ID" -q -o "BatchMode=yes" -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null")
    SSH_INT_OPTS=(-i "$SSH_ID" -q -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null")
else
    SSH_OPTS=(-q -o "BatchMode=yes" -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null")
    SSH_INT_OPTS=(-q -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null")
fi

extract_num() {
    local val=$(echo "$1" | sed -E 's/[^0-9]//g')
    echo "${val:-0}" # Safely fallback to 0 if empty
}

confirm_or_abort() {
    local prompt_msg="$1"

    # Auto-confirm if -a flag was passed
    if [ "$ACCEPT_DEFAULTS" = true ]; then
        return 0
    fi

    echo -ne "${prompt_msg} [y/N]: "
    read -r confirm_input
    if [[ ! "$confirm_input" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${BRED}Action aborted by user. Exiting.${NC}"
        exit 1
    fi
}

get_default() {
    grep -E "^\s*\{\%\s*set\s+custom_$1\s*=" "$CLOUD_INIT" | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*%\}.*//; s/^"//; s/"$//'
}

# Prompt Helper Function - ask_var "Prompt Text" "jinja_var_name" "bash_var_name" [dynamic_fallback]
ask_var() {
    local prompt_text="$1"
    local config_key="$2"
    local var_name="$3"
    local dynamic_fallback="$4"
    local default_val=""
    local user_input

    # Extract default from Jinja cloud-init template
    if [ -n "$config_key" ] && [ -f "$CLOUD_INIT" ]; then
        default_val=$(get_default "$config_key")
    fi

    # Apply dynamic fallback if Jinja template was empty
    if [ -z "$default_val" ] && [ -n "$dynamic_fallback" ]; then
        default_val="$dynamic_fallback"
    fi

    if [ "$ACCEPT_DEFAULTS" = true ]; then
        user_input="$default_val"
    else
        echo -ne "  ${BYELLOW}${prompt_text} [${NC}${default_val}${BYELLOW}]: ${NC}"
        read -r user_input
        
        if [ -z "$user_input" ]; then
            user_input="$default_val"
        fi
    fi

    # Smart GiB appending
    if [[ "$default_val" == *"GiB" ]] && [[ "$user_input" =~ ^[0-9]+$ ]]; then
        user_input="${user_input}GiB"
    fi

    # Export to LXC args if a config key exists
    if [ -n "$config_key" ]; then
        LXC_OPTIONAL_ARGS+=("-c" "user.${config_key}=${user_input}")
    fi

    # Bind to bash variable if requested
    if [ -n "$var_name" ]; then
        eval "$var_name=\"\$user_input\""
    fi
}

# ==========================================
# INTERACTIVE VARIABLE COLLECTION
# ==========================================

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo -e "${BYELLOW}--- 1. Authentication & System ---${NC}"
fi
ask_var "System User" "user" "SYS_USER"
ask_var "System Password" "password" ""
ask_var "Hostname" "hostname" "" "$VM_NAME"
ask_var "Top Level Domain" "tld" "MAAS_DOMAIN"
ask_var "Timezone" "timezone" ""

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo ""
    echo -e "${BYELLOW}--- 2. Snap Channels ---${NC}"
fi
ask_var "LXD Channel" "lxd_channel" ""
ask_var "MAAS Channel" "maas_channel" ""
ask_var "Sunbeam Channel" "sunbeam_channel" ""

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo ""
    echo -e "${BYELLOW}--- 3. LXD & MAAS Base Settings ---${NC}"
fi
# Dynamic LXD Project and Bridge Prompts
ask_var "LXD Project Name" "lxd_project" "LXD_PROJECT"
ask_var "LXD Storage Pool" "lxd_pool" "POOL_NAME"

CREATED_LXD_BRIDGE=false
LXD_BRIDGE_TO_DELETE=""
CREATE_CUSTOM_LXD_BRIDGE=false

if [ "$NO_NEST" = true ]; then
    if [ "$ACCEPT_DEFAULTS" = true ]; then
        LXD_BRIDGE="$RANDOM_MAAS_BRIDGE"
    else
        echo -ne "  ${BYELLOW}Host's LXD Bridge Name [${NC}${RANDOM_MAAS_BRIDGE}${BYELLOW}]: ${NC}"
        read -r user_input
        LXD_BRIDGE="${user_input:-$RANDOM_MAAS_BRIDGE}"
    fi
    LXC_OPTIONAL_ARGS+=("-c" "user.lxd_bridge=$LXD_BRIDGE")
    
    # 3-Path CIDR Logic
    if [ "$LXD_BRIDGE" = "$RANDOM_MAAS_BRIDGE" ]; then
        # Using random bridge, create it and obtain CIDR
        confirm_or_abort "    Create new random bridge '$LXD_BRIDGE' to auto-assign CIDR?"
        
        echo "    Creating random managed non-DHCP + NAT MAAS bridge '$LXD_BRIDGE'...${NC}"
        if ! lxc network create "$LXD_BRIDGE" ipv4.nat=true ipv4.dhcp=false ipv6.address=none; then
            echo -e "${BRED}Fatal Error: Failed to create random LXD bridge '$LXD_BRIDGE'. Exiting.${NC}"
            exit 1
        fi
        CREATED_LXD_BRIDGE=true
        LXD_BRIDGE_TO_DELETE="$LXD_BRIDGE"
        
        AUTO_IP=$(lxc network get "$LXD_BRIDGE" ipv4.address)
        MAAS_CIDR=$(echo "$AUTO_IP" | awk -F'[/.]' '{print $1"."$2"."$3".0/"$5}')
        echo -e "  ${BYELLOW}-> Auto-assigned Host's MAAS Subnet CIDR: ${NC}${MAAS_CIDR}"
        
    elif lxc network show "$LXD_BRIDGE" >/dev/null 2>&1; then
        # Using existing bridge, obtain CIDR
        echo -e "  ${BYELLOW}-> Bridge '$LXD_BRIDGE' already exists. Fetching CIDR...${NC}"

        AUTO_IP=$(lxc network get "$LXD_BRIDGE" ipv4.address)
        MAAS_CIDR=$(echo "$AUTO_IP" | awk -F'[/.]' '{print $1"."$2"."$3".0/"$5}')
        echo -e "  ${BYELLOW}-> Fetched Host's MAAS Subnet CIDR: ${NC}${MAAS_CIDR}"
        
    else
        # Creating new bridge, ask for CIDR
        JINJA_CIDR=$(get_default "maas_subnet")
        if [ "$ACCEPT_DEFAULTS" = true ]; then
            MAAS_CIDR="$JINJA_CIDR"
        else
            echo -e "  ${BYELLOW}Host's MAAS Subnet CIDR [${NC}${JINJA_CIDR}${BYELLOW}]: ${NC}"
            read -r user_input
            MAAS_CIDR="${user_input:-$JINJA_CIDR}"
        fi
        CREATE_CUSTOM_LXD_BRIDGE=true
    fi
    LXC_OPTIONAL_ARGS+=("-c" "user.maas_subnet=$MAAS_CIDR")
else
    # Nested LXD external bridge
    if [ "$ACCEPT_DEFAULTS" = true ]; then
        HOST_BRIDGE="$RANDOM_MAAS_BRIDGE"
    else
        echo -ne "  ${BYELLOW}Host's LXD Bridge (For VM Attachment) [${NC}${RANDOM_MAAS_BRIDGE}${BYELLOW}]: ${NC}"
        read -r user_input
        HOST_BRIDGE="${user_input:-$RANDOM_MAAS_BRIDGE}"
    fi
    
    # 3-Path CIDR Logic
    if [ "$HOST_BRIDGE" = "$RANDOM_MAAS_BRIDGE" ]; then
        # Using random bridge, create it
        confirm_or_abort "    Create new random bridge '$HOST_BRIDGE' for nested VM uplink?"
        
        echo "    Creating random managed DHCP + NAT Host Bridge '$HOST_BRIDGE'...${NC}"
        if ! lxc network create "$HOST_BRIDGE" ipv4.nat=true ipv6.address=none; then
            echo -e "${BRED}Fatal Error: Failed to create random LXD bridge '$HOST_BRIDGE'. Exiting.${NC}"
            exit 1
        fi
        CREATED_LXD_BRIDGE=true
        LXD_BRIDGE_TO_DELETE="$HOST_BRIDGE"
        
    elif lxc network show "$HOST_BRIDGE" >/dev/null 2>&1; then
        # Using existing bridge
        echo -e "  ${BYELLOW}-> Bridge '$HOST_BRIDGE' already exists. Using as uplink...${NC}"
    else
        # Creating new bridge
        CREATE_CUSTOM_LXD_BRIDGE=true
    fi
fi
ask_var "MAAS Admin User" "maas_user" ""
ask_var "MAAS Admin Password" "maas_password" ""
ask_var "MAAS Admin Email" "maas_email" ""
ask_var "MAAS DNS Forwarder" "maas_dns" "MAAS_DNS"
ask_var "MAAS Network Space" "maas_space" ""
ask_var "MAAS Deploy Images (space separated)" "maas_images" ""

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo ""
    echo -e "${BYELLOW}--- 4. OpenStack Deployment ---${NC}"
fi
ask_var "OpenStack Deployment Name" "os_deployment" ""

CREATED_NEUTRON_BRIDGE=false
NEUTRON_BRIDGE_TO_DELETE=""
CREATE_CUSTOM_NEUTRON_BRIDGE=false

if [ "$NO_NEST" = true ]; then
    if [ "$ACCEPT_DEFAULTS" = true ]; then
        NEUTRON_BRIDGE="$RANDOM_NEU_BRIDGE"
    else
        echo -ne "  ${BYELLOW}Host's Neutron Bridge Name [${NC}${RANDOM_NEU_BRIDGE}${BYELLOW}]: ${NC}"
        read -r user_input
        NEUTRON_BRIDGE="${user_input:-$RANDOM_NEU_BRIDGE}"
    fi
    LXC_OPTIONAL_ARGS+=("-c" "user.os_neutron_bridge=$NEUTRON_BRIDGE")
    
    # 3-Path CIDR Logic
    if [ "$NEUTRON_BRIDGE" = "$RANDOM_NEU_BRIDGE" ]; then
        # Using random bridge, create it and obtain CIDR
        confirm_or_abort "    Create new random bridge '$NEUTRON_BRIDGE' to auto-assign CIDR?"
        
        echo "    Creating random managed DHCP + NAT Neutron bridge '$NEUTRON_BRIDGE'...${NC}"
        if ! lxc network create "$NEUTRON_BRIDGE" ipv4.nat=true ipv4.dhcp=true ipv6.address=none; then
            echo -e "${BRED}Fatal Error: Failed to create random Neutron bridge '$NEUTRON_BRIDGE'. Exiting.${NC}"
            exit 1
        fi
        CREATED_NEUTRON_BRIDGE=true
        NEUTRON_BRIDGE_TO_DELETE="$NEUTRON_BRIDGE"
        
        AUTO_IP=$(lxc network get "$NEUTRON_BRIDGE" ipv4.address)
        NEUTRON_CIDR=$(echo "$AUTO_IP" | awk -F'[/.]' '{print $1"."$2"."$3".0/"$5}')
        echo -e "  ${BYELLOW}-> Auto-assigned Host's Neutron CIDR: ${NC}${NEUTRON_CIDR}"
        
    elif lxc network show "$NEUTRON_BRIDGE" >/dev/null 2>&1; then
        # Using existing bridge, obtain CIDR
        echo -e "  ${BYELLOW}-> Bridge '$NEUTRON_BRIDGE' already exists. Fetching CIDR...${NC}"
        
        AUTO_IP=$(lxc network get "$NEUTRON_BRIDGE" ipv4.address)
        NEUTRON_CIDR=$(echo "$AUTO_IP" | awk -F'[/.]' '{print $1"."$2"."$3".0/"$5}')
        echo -e "  ${BYELLOW}-> Fetched Host's Neutron CIDR: ${NC}${NEUTRON_CIDR}"
        
    else
        # Creating new bridge, ask for CIDR
        JINJA_CIDR=$(get_default "os_neutron_cidr")
        if [ "$ACCEPT_DEFAULTS" = true ]; then
            NEUTRON_CIDR="$JINJA_CIDR"
        else
            echo -ne "  ${BYELLOW}Host's Neutron CIDR [${NC}${JINJA_CIDR}${BYELLOW}]: ${NC}"
            read -r user_input
            NEUTRON_CIDR="${user_input:-$JINJA_CIDR}"
        fi
        CREATE_CUSTOM_NEUTRON_BRIDGE=true
    fi
    LXC_OPTIONAL_ARGS+=("-c" "user.os_neutron_cidr=$NEUTRON_CIDR")
fi

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo ""
    echo -e "${BYELLOW}--- 5. Hardware & Scaling Allocation ---${NC}"
fi
ask_var "Number of HA Nodes (1 or 3+)" "ha_nodes" "HA_NODES"

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo "  -- MAAS Node Resources --"
fi
ask_var "MAAS Server CPU cores" "maas_cpu" "MAAS_CPU"
ask_var "MAAS Server RAM" "maas_ram" "MAAS_RAM"
ask_var "MAAS Server Root Disk" "maas_disk" "MAAS_DISK"

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo "  -- Juju Controllers --"
fi
ask_var "Juju Controller CPU cores" "juju_cpu" "JUJU_CPU"
ask_var "Juju Controller RAM" "juju_ram" "JUJU_RAM"
ask_var "Juju Controller Root Disk" "juju_disk" "JUJU_DISK"

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo "  -- Sunbeam Controllers --"
fi
ask_var "Sunbeam Controller CPU cores" "sunbeam_cpu" "SUNBEAM_CPU"
ask_var "Sunbeam Controller RAM" "sunbeam_ram" "SUNBEAM_RAM"
ask_var "Sunbeam Controller Root Disk" "sunbeam_disk" "SUNBEAM_DISK"

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo "  -- Cloud Compute/Storage Nodes --"
fi
ask_var "Cloud Node CPU cores" "cloud_cpu" "CLOUD_CPU"
ask_var "Cloud Node RAM" "cloud_ram" "CLOUD_RAM"
ask_var "Cloud Node Root Disk" "cloud_disk" "CLOUD_DISK"
ask_var "Cloud Node OSD Disk (Each)" "cloud_osd_disk" "CLOUD_OSD"
ask_var "Number of OSDs per Cloud Node" "osds_per_node" "OSDS_PER"

if [ "$ACCEPT_DEFAULTS" = false ]; then
    echo ""
fi

# ==========================================
# RESOURCE CALCULATION
# ==========================================

# Network Math (Only override if NO_NEST = true)
if [ "$NO_NEST" = true ]; then
    
    # 1. MAAS CIDR Calculation
    read -r RET_GW MAAS_S MAAS_E INT_S INT_E PUB_S PUB_E M_MASK STATIC_IP <<< "$(python3 -c "
import ipaddress, sys
try:
    net = ipaddress.IPv4Network('$MAAS_CIDR', strict=False)
    hosts = list(net.hosts())
    if len(hosts) < 50:
        print('ERROR_TINY')
        sys.exit()
    gw = hosts[0]
    static = hosts[1] # .2 for static binding
    if len(hosts) >= 255:
        maas_e, maas_s = hosts[-1], hosts[-55]
        int_e, int_s = hosts[-56], hosts[-155]
        pub_e, pub_s = hosts[-156], hosts[-255]
    else:
        maas_e, maas_s = hosts[-1], hosts[-10]
        int_e, int_s = hosts[-11], hosts[-25]
        pub_e, pub_s = hosts[-26], hosts[2]
    print(f'{gw} {maas_s} {maas_e} {int_s} {int_e} {pub_s} {pub_e} {net.prefixlen} {static}')
except Exception:
    print('ERROR')
")"
    
    # Abort on MAAS Math Failure
    if [[ "$RET_GW" == "ERROR"* ]] || [ -z "$RET_GW" ]; then
        echo -e "${BRED}Fatal Error: Invalid MAAS CIDR ('${NC}${MAAS_CIDR}${BRED}') or subnet too small.${NC}"
        exit 1
    fi
    
    LXC_OPTIONAL_ARGS+=("-c" "user.maas_subnet=$MAAS_CIDR")
    LXC_OPTIONAL_ARGS+=("-c" "user.maas_gateway=$RET_GW")
    LXC_OPTIONAL_ARGS+=("-c" "user.maas_ip_start=$MAAS_S")
    LXC_OPTIONAL_ARGS+=("-c" "user.maas_ip_end=$MAAS_E")
    LXC_OPTIONAL_ARGS+=("-c" "user.os_int_api_start=$INT_S")
    LXC_OPTIONAL_ARGS+=("-c" "user.os_int_api_end=$INT_E")
    LXC_OPTIONAL_ARGS+=("-c" "user.os_pub_api_start=$PUB_S")
    LXC_OPTIONAL_ARGS+=("-c" "user.os_pub_api_end=$PUB_E")
    
    MAAS_GW_IP="$RET_GW"
    MAAS_MASK="$M_MASK"
    MAAS_STATIC_IP="$STATIC_IP"
    
    # 2. Neutron CIDR Calculation
    read -r NEU_GW N_MASK <<< "$(python3 -c "
import ipaddress, sys
try:
    net = ipaddress.IPv4Network('$NEUTRON_CIDR', strict=False)
    print(f'{list(net.hosts())[0]} {net.prefixlen}')
except Exception:
    print('ERROR')
")"
    
    # Abort on Neutron Math Failure
    if [ "$NEU_GW" = "ERROR" ] || [ -z "$NEU_GW" ]; then
        echo -e "${BRED}Fatal Error: Invalid Neutron CIDR ('${NC}${NEUTRON_CIDR}${BRED}').${NC}"
        exit 1
    fi
    
    LXC_OPTIONAL_ARGS+=("-c" "user.os_neutron_cidr=$NEUTRON_CIDR")
    
    NEUTRON_GW_IP="$NEU_GW"
    NEUTRON_MASK="$N_MASK"
fi

# Extract numbers
M_R=$(extract_num "$MAAS_RAM")
M_D=$(extract_num "$MAAS_DISK")
J_R=$(extract_num "$JUJU_RAM")
J_D=$(extract_num "$JUJU_DISK")
S_R=$(extract_num "$SUNBEAM_RAM")
S_D=$(extract_num "$SUNBEAM_DISK")
C_R=$(extract_num "$CLOUD_RAM")
C_D=$(extract_num "$CLOUD_DISK")
O_D=$(extract_num "$CLOUD_OSD")
H_N=$(extract_num "$HA_NODES")
O_P=$(extract_num "$OSDS_PER")

# Resource Math
if [ "$NO_NEST" = true ]; then
    CPU_LIMIT="$MAAS_CPU"
    RAM_LIMIT="${M_R}GiB"
    DISK_LIMIT="${M_D}GiB"
else
    # Nested requires ( MAAS + (All Nodes * HA Nodes) + (OSDs * Per Node * HA Nodes) + overhead )
    CPU_LIMIT=$(( MAAS_CPU + (JUJU_CPU * H_N) + (SUNBEAM_CPU * H_N) + (CLOUD_CPU * H_N) ))
    TOT_RAM=$(( M_R + (J_R * H_N) + (S_R * H_N) + (C_R * H_N) ))
    TOT_DISK=$(( M_D + (J_D * H_N) + (S_D * H_N) + (C_D * H_N) + (O_D * O_P * H_N) + 10))
    
    RAM_LIMIT="${TOT_RAM}GiB"
    DISK_LIMIT="${TOT_DISK}GiB"
fi

# ==========================================
# EXECUTION
# ==========================================

# Non-nested static IP network configuration
if [ "$NO_NEST" = true ]; then
    
    # 1. Create custom MAAS bridge if required
    if [ "$CREATE_CUSTOM_LXD_BRIDGE" = true ]; then
        echo ""
        confirm_or_abort "  Create managed custom MAAS bridge '$LXD_BRIDGE' (${MAAS_GW_IP}/${MAAS_MASK})?"
        
        echo "  Creating managed non-DHCP + NAT MAAS bridge '$LXD_BRIDGE' ($MAAS_GW_IP)..."
        if ! lxc network create "$LXD_BRIDGE" \
          ipv4.address="${MAAS_GW_IP}/${MAAS_MASK}" \
          ipv4.nat=true \
          ipv4.dhcp=false \
          ipv6.address=none; then
            echo -e "${BRED}Fatal Error: Failed to create custom MAAS bridge '$LXD_BRIDGE'. Exiting.${NC}"
            exit 1
        fi
        
        CREATED_LXD_BRIDGE=true
        LXD_BRIDGE_TO_DELETE="$LXD_BRIDGE"
    fi
    
    # 2. Create custom Neutron bridge if required
    if [ "$CREATE_CUSTOM_NEUTRON_BRIDGE" = true ]; then
        echo ""
        confirm_or_abort "  Create managed custom Neutron bridge '$NEUTRON_BRIDGE' (${NEUTRON_GW_IP}/${NEUTRON_MASK})?"
        
        echo "  Creating managed DHCP + NAT Neutron bridge '$NEUTRON_BRIDGE' ($NEUTRON_GW_IP)..."
        if ! lxc network create "$NEUTRON_BRIDGE" \
          ipv4.address="${NEUTRON_GW_IP}/${NEUTRON_MASK}" \
          ipv4.nat=true \
          ipv4.dhcp=true \
          ipv6.address=none; then
            echo -e "${BRED}Fatal Error: Failed to create custom Neutron bridge '$NEUTRON_BRIDGE'. Exiting.${NC}"
            exit 1
        fi
        
        CREATED_NEUTRON_BRIDGE=true
        NEUTRON_BRIDGE_TO_DELETE="$NEUTRON_BRIDGE"
    fi
    
    [[ -z "$MAAS_DOMAIN" ]] && MAAS_DOMAIN="maas"
    
    # Set netplan config with static IP, non DHCP and MAAS DNS server
    read -r -d '' STATIC_NET <<EOF
network:
  version: 2
  ethernets:
    enp5s0:
      dhcp4: false
      addresses: [${MAAS_STATIC_IP}/${MAAS_MASK}]
      routes:
        - to: default
          via: $MAAS_GW_IP
      nameservers:
        addresses: [${MAAS_STATIC_IP}, ${MAAS_DNS}]
        search: [${MAAS_DOMAIN}, maas]
EOF
    
    # Inject static net config and attach to the custom non-nested bridge
    LXC_OPTIONAL_ARGS+=("-c" "cloud-init.network-config=$STATIC_NET")
    LXC_OPTIONAL_ARGS+=("-d" "eth0,network=$LXD_BRIDGE")
else
    # Create custom LXD bridge if required
    if [ "$CREATE_CUSTOM_LXD_BRIDGE" = true ]; then
        echo ""
        confirm_or_abort "  Create managed custom LXD bridge '${HOST_BRIDGE}'?"
        
        echo "  Creating managed DHCP + NAT Host Bridge '$HOST_BRIDGE'..."
        lxc network create "$HOST_BRIDGE" ipv4.nat=true ipv6.address=none
        
        CREATED_LXD_BRIDGE=true
        LXD_BRIDGE_TO_DELETE="$HOST_BRIDGE"
    fi
    LXC_OPTIONAL_ARGS+=("-d" "eth0,network=$HOST_BRIDGE")
fi

# 1. Launch VM
echo -e "${BYELLOW}-> 1. Launching LXD VM '${NC}$VM_NAME${BYELLOW}' (${NC}$IMAGE${BYELLOW}) with CPU: ${NC}$CPU_LIMIT${BYELLOW} cores ; RAM: ${NC}$RAM_LIMIT${BYELLOW} ; DISK: ${NC}$DISK_LIMIT"
echo ""

if ! lxc launch "$IMAGE" "$VM_NAME" --vm \
  -c limits.cpu="$CPU_LIMIT" \
  -c limits.memory="$RAM_LIMIT" \
  -d root,size="$DISK_LIMIT" \
  "${LXC_OPTIONAL_ARGS[@]}" \
  -c cloud-init.user-data="$(cat "$CLOUD_INIT")"; then
    echo -e "${BRED}Error: Failed to launch VM. Exiting. ${NC}"
    exit 1
fi

# 2. Generate Cleanup Script
CLEANUP_SCRIPT="$SCRIPT_DIR/destroy-${VM_NAME}.sh"

cat << EOF > "$CLEANUP_SCRIPT"
#!/bin/bash

echo -e "${BYELLOW}----- Starting Cleanup for $VM_NAME -----${NC}"
echo ""

# 1. Delete the VM
echo -e "${BYELLOW}-> 1. Stopping and Deleting LXD VM: $VM_NAME... ${NC}"
echo ""
if lxc info "$VM_NAME" >/dev/null 2>&1; then
    lxc stop -f "$VM_NAME" 2 || true
    sleep 2 # Wait for Ceph/OSD storage locks to release
    lxc delete -f "$VM_NAME"
else
    echo "VM '$VM_NAME' not found, skipping..."
    echo ""
fi

# 2. ONLY purge project if NO_NEST is true AND the project is NOT 'default'
if [[ "$NO_NEST" == "true" ]]; then

    echo -e "${BYELLOW}-> 2. Cleaning up dedicated LXD project: $LXD_PROJECT... ${NC}"
    echo ""

    if [[ "$LXD_PROJECT" != "default" ]]; then
        if lxc project list | grep -q " $LXD_PROJECT "; then
            
            # Delete all instances inside the $LXD_PROJECT project first
            echo "Stopping and deleting all instances in project '$LXD_PROJECT'..."
            for inst in \$(lxc list --project $LXD_PROJECT --format json | jq -r '.[].name'); do
                lxc stop -f --project $LXD_PROJECT "\$inst" || true
                lxc delete -f --project $LXD_PROJECT "\$inst"
            done
            
            sleep 2 # Wait for Ceph/OSD storage locks to release
            
            # Delete all storage volumes inside the $LXD_PROJECT project
            echo "Deleting storage volumes in project '$LXD_PROJECT'..."
            for vol in \$(lxc storage volume list $POOL_NAME --project $LXD_PROJECT --format json | jq -r '.[] | select(.type=="custom") | .name'); do
                lxc storage volume delete $POOL_NAME "\$vol" --project $LXD_PROJECT
            done
            
            # Delete all images inside the $LXD_PROJECT project
            echo "Deleting images in project '$LXD_PROJECT'..."
            for img in \$(lxc image list --project $LXD_PROJECT --format json | jq -r '.[].fingerprint'); do
                lxc image delete --project $LXD_PROJECT "\$img"
            done
            
            # Switch to default to ensure we aren't "inside" the project we are deleting
            lxc project switch default >/dev/null 2>&1
            lxc project delete $LXD_PROJECT
        else
            echo "LXD project '$LXD_PROJECT' not found, skipping..."
            echo ""
        fi
    else
        echo "Selected '$LXD_PROJECT' LXD project, skipping... (Leaving cleanup to user)"
        echo ""
    fi
fi

# 3. Delete the Host/MAAS Bridge (if we auto-generated it)
if [ "$CREATED_LXD_BRIDGE" = true ]; then
    echo -e "${BYELLOW}-> 3. Deleting unique LXD Bridge: $LXD_BRIDGE_TO_DELETE... ${NC}"
    echo ""
    if lxc network show "$LXD_BRIDGE_TO_DELETE" >/dev/null 2>&1; then
        lxc network delete "$LXD_BRIDGE_TO_DELETE"
    else
        echo "LXD Bridge '$LXD_BRIDGE_TO_DELETE' not found, skipping..."
        echo ""
    fi
fi

# 4. Delete the Neutron Bridge (if we auto-generated it)
if [ "$CREATED_NEUTRON_BRIDGE" = true ]; then
    echo -e "${BYELLOW}-> 4. Deleting unique Neutron Bridge: $NEUTRON_BRIDGE_TO_DELETE... ${NC}"
    echo ""
    if lxc network show "$NEUTRON_BRIDGE_TO_DELETE" >/dev/null 2>&1; then
        lxc network delete "$NEUTRON_BRIDGE_TO_DELETE"
    else
        echo "Neutron Bridge '$NEUTRON_BRIDGE_TO_DELETE' not found, skipping..."
        echo ""
    fi
fi

echo -e "${BYELLOW}----- Cleanup Complete -----${NC}"
# rm -- "\$0" # Self-deletion removed for auditing purposes.
EOF

chmod +x "$CLEANUP_SCRIPT"

echo ""
echo -e "${BYELLOW}-> 2. Cleanup script created:${NC} $CLEANUP_SCRIPT"

# 3. Watch for IP Address
echo ""
echo -e "${BYELLOW}-> 3. Obtaining IP Address... ${NC}"
echo ""

# Loop until we get an IPv4 address on eth0 (or enp5s0)
IP=""
TIMEOUT=0

while [ -z "$IP" ]; do
    if [ "$TIMEOUT" -ge "$MAX_WAIT" ]; then
        echo -e "${BRED}Fatal Error: Timed out waiting for VM to get an IP address.${NC}"
        echo -e "Run '${NC}${CLEANUP_SCRIPT}${BYELLOW}' to clean up the environment.${NC}"
        exit 1
    fi

    IP=$(lxc list "$VM_NAME" --format=json | jq -r '.[0].state.network | to_entries[] | select(.key=="eth0" or .key=="enp5s0") | .value.addresses[] | select(.family=="inet" and .scope=="global") | .address' | head -n 1)

    if [ -z "$IP" ]; then
        sleep 2
        TIMEOUT=$((TIMEOUT + 2))
    fi
done

echo "Target IP: $IP"
echo ""

lxc list

# 4. Wait for cloud-init to finish and tail logs and then Juju watch
echo ""
echo -e "${BYELLOW}-> 4. Connecting to live Cloud-Init logs... (Will switch to Juju Status) ${NC}"
echo ""

PHASE="LOG_TAIL" 
JUJU_TRIGGER_MSG="-------- Bootstrapping the orchestration layer... --------"

# Phase options: LOG_TAIL, JUJU_WATCH, DONE

while [ "$PHASE" != "DONE" ]; do

    # PHASE A: LOG TAILING
    if [ "$PHASE" == "LOG_TAIL" ]; then
        # We use sed to quit 'q' if we see the Trigger Message OR "finished at"
        ssh "${SSH_OPTS[@]}" -t "${SYS_USER}@$IP" "tail -f /var/log/cloud-init-output.log 2>/dev/null | sed '/$JUJU_TRIGGER_MSG/ q; /finished at/ q'"
        
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            # Success! The 'sed' command found the Juju model deploy start and quit cleanly.
            STATUS_CHECK=$(ssh "${SSH_OPTS[@]}" "${SYS_USER}@$IP" "cloud-init status" 2>/dev/null)
            
            if [[ "$STATUS_CHECK" == *"status: done"* ]]; then
                echo ""
                echo -e "${BYELLOW}Cloud-init finished successfully! ${NC}${CLR_EOL}"
                PHASE="DONE"
            else
                echo ""
                echo -e "${BYELLOW}Juju Deployment Trigger Detected. Switching to Watch Mode... ${NC}${CLR_EOL}"
                sleep 2
                PHASE="JUJU_WATCH"
            fi

        elif [ $EXIT_CODE -eq 255 ]; then
            # 255 = SSH died (Connection Refused / Network Down / Rebooting)
            echo -ne "${BYELLOW}Connection lost (Rebooting?) retrying... ${NC}${CLR_EOL}\r"
            sleep 3
        else
            # Other errors (file not found yet, etc)
            echo -ne "${BYELLOW}Waiting for log file creation... ${NC}${CLR_EOL}\r"
            sleep 2
        fi
    fi

    # PHASE B: JUJU WATCH
    if [ "$PHASE" == "JUJU_WATCH" ]; then

        # This command attempts to query the models in reverse order of creation
        JUJU_CMD="juju status -m openstack --color 2>/dev/null || juju status -m openstack-machines --color 2>/dev/null || juju status -m openstack-infra --color 2>/dev/null || juju status -m controller --color 2>/dev/null || echo 'Waiting for Juju models to initialize...'"

        # Capture both status commands first
        JUJU_OUTPUT=$(ssh "${SSH_OPTS[@]}" "${SYS_USER}@$IP" "$JUJU_CMD" 2>/dev/null)
        LOG_OUTPUT=$(ssh "${SSH_OPTS[@]}" "${SYS_USER}@$IP" "tail -n 7 /var/log/cloud-init-output.log | sed 's/\r$//' | sed 's/.*\r//' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'" 2>/dev/null)
        SSH_EXIT=$?
        CI_STATUS=$(ssh "${SSH_OPTS[@]}" "${SYS_USER}@$IP" "cloud-init status" 2>/dev/null)

        # Check if we should stop (Is cloud-init done?)
        if [[ "$CI_STATUS" == *"status: done"* ]]; then
            # Print the final status one last time cleanly
            echo -e "${CURSOR_TOP}${BYELLOW}-> 5. Juju Deployment Status (Finalizing...)${NC}${CLR_EOL}"
            echo -e "Target IP: $IP | Updated: $(date +%T)${CLR_EOL}"
            echo -e "${BYELLOW}-------------------------------------------------------${NC}${CLR_EOL}"
            echo -e "$JUJU_OUTPUT" | sed "s/$/${CLR_EOL}/"
            echo -e "${CLEAR_REST}" # Clean up bottom
            echo ""
            echo -e "${BYELLOW}Cloud-init finished successfully! ${NC}"
            PHASE="DONE"
            break
        fi

        # Repaint screen
        if [ $SSH_EXIT -eq 0 ]; then
            # Move cursor to top (0,0) -> Print Data -> Clear remaining junk at bottom
            echo -ne "${CURSOR_TOP}"

            # Header
            echo -e "${BYELLOW}-> 5. Juju Deployment Status (Cloud-Init is running...)${NC}${CLR_EOL}"
            echo -e "Target IP: $IP | Updated: $(date +%T)${CLR_EOL}"

            # Tail 7 lines of cloud-init logs
            echo -e "${BYELLOW}--------------------- Latest Logs ---------------------${NC}${CLR_EOL}"
            # Print logs, ensuring we wipe the end of the line for every log entry
            if [ -n "$LOG_OUTPUT" ]; then
                echo -e "$LOG_OUTPUT" | sed "s/$/${CLR_EOL}/"
            else
                echo -e "(Waiting for logs...)${CLR_EOL}"
            fi

            # Juju watch
            echo -e "${BYELLOW}--------------------- Juju Status ---------------------${NC}${CLR_EOL}"

            # Get terminal height (default to 64 if it fails)
            TERM_HEIGHT=$(tput lines 2>/dev/null || echo 64)
            
            # Reserve 13 lines for cloud-init logs + header
            MAX_JUJU_LINES=$(( TERM_HEIGHT - 13 ))
            if [ "$MAX_JUJU_LINES" -lt 5 ]; then MAX_JUJU_LINES=5; fi # Fallback for tiny windows
            
            JUJU_LINE_COUNT=$(echo "$JUJU_OUTPUT" | wc -l)

            # Print Juju output: Truncate if it exceeds available terminal lines
            if [ "$JUJU_LINE_COUNT" -gt "$MAX_JUJU_LINES" ]; then
                HIDDEN_LINES=$(( JUJU_LINE_COUNT - MAX_JUJU_LINES ))
                echo -e "$JUJU_OUTPUT" | head -n "$MAX_JUJU_LINES" | sed "s/$/${CLR_EOL}/"
                echo -e "... [ Output truncated by $HIDDEN_LINES lines to fit terminal. Maximize window to see more! ] ...${CLR_EOL}"
            else
                echo -e "$JUJU_OUTPUT" | sed "s/$/${CLR_EOL}/"
            fi
            
            # Clear whatever is left at the very bottom of the screen (in case list got shorter)
            echo -ne "${CLEAR_REST}"
        else
            # If SSH fails, just print a warning on top, don't wipe screen
            echo -ne "${CURSOR_TOP}${BYELLOW}Connection lost. Reconnecting...${NC}${CLR_EOL}\r"
        fi

        # Standard refresh rate
        sleep 3
    fi
done

# 6. Open dashboard in browser
echo ""
echo -e "${BYELLOW}-> 6. Opening MAAS Dashboard... ${NC}"

# Open Browser
if command -v xdg-open &> /dev/null; then
    xdg-open "http://$IP:5240/MAAS/" > /dev/null 2>&1 &
fi

# 7. Obtain Horizon dashboard URL
echo ""
echo -e "${BYELLOW}-> 7. Obtaining Horizon Dashboard URL... ${NC}"
echo ""

DASHBOARD_URL=$(ssh "${SSH_OPTS[@]}" "${SYS_USER}@$IP" "juju status -m openstack horizon | grep -o 'http[s]*://[^ ]*'" 2>/dev/null | head -n 1)

echo "Horizon Dashboard URL: $DASHBOARD_URL"

# 8. Open Horizon dashboard in browser
echo ""
echo -e "${BYELLOW}-> 8. Opening Horizon Dashboard... ${NC}"

# Open Browser
if command -v xdg-open &> /dev/null; then
    xdg-open "$DASHBOARD_URL" > /dev/null 2>&1 &
fi

# 9. Final Interactive Shell
echo ""
echo -e "${BYELLOW}-> 9. Dropping into interactive shell... ${NC}"
echo ""
# Force cursor to reappear
echo -e "\033[?25h"
ssh "${SSH_INT_OPTS[@]}" "${SYS_USER}@$IP"

