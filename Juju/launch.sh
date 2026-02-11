#!/bin/bash

set +e

# Configuration
VM_NAME="juju-maas"
IMAGE="ubuntu:24.04"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

CLOUD_INIT="$SCRIPT_DIR/cloud-init/cloud-config.yaml"
CLOUD_INIT_NN="$SCRIPT_DIR/cloud-init/cloud-config-nn.yaml"
CLOUD_INIT_SNAP="$SCRIPT_DIR/cloud-init/cloud-config-snap.yaml"
CLOUD_INIT_SNAP_NN="$SCRIPT_DIR/cloud-init/cloud-config-snap-nn.yaml"

CPU_LIMIT="12"
RAM_LIMIT="28GiB"
DISK_LIMIT="120GiB"

CLR_EOL=$'\033[K'

SNAP=false
NO_NEST=false
PROFILE="default"
MAAS_PROJECT_NAME="maas"
CUSTOM_NAME_SET=false

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --snap)
            SNAP=true
            shift 1
            ;;
        --nn)
            NO_NEST=true
            shift 1
            ;;
        *)
            VM_NAME="$1"
            shift 1
            ;;
    esac
done

if [ "$SNAP" = true ] && [ "$NO_NEST" = true ]; then
    echo -e "${BYELLOW}-> Switch enabled: Using Snap non nested LXD cloud-init config. ${NC}"
    echo ""
    CLOUD_INIT="$CLOUD_INIT_SNAP_NN"
    if [ "$CUSTOM_NAME_SET" = false ]; then
        VM_NAME="juju-maas-snap"
    fi
    CPU_LIMIT="2"
    RAM_LIMIT="6GiB"
    DISK_LIMIT="20GiB"
    PROFILE="maas"

elif [ "$SNAP" = true ]; then
    echo -e "${BYELLOW}-> Switch enabled: Using Snap cloud-init config. ${NC}"
    echo ""
    CLOUD_INIT="$CLOUD_INIT_SNAP"
    if [ "$CUSTOM_NAME_SET" = false ]; then
        VM_NAME="juju-maas-snap"
    fi

elif [ "$NO_NEST" = true ]; then
    echo -e "${BYELLOW}-> Switch enabled: Using non nested LXD cloud-init config. ${NC}"
    echo ""
    CLOUD_INIT="$CLOUD_INIT_NN"
    CPU_LIMIT="2"
    RAM_LIMIT="6GiB"
    DISK_LIMIT="20GiB"
    PROFILE="maas"
fi

# --- Colors ---
# Check if stderr is a TTY
if [ -t 2 ]; then
    RED='\033[1;31m'
    BYELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    BYELLOW=''
    NC=''
fi

# Check for cloud-init file
if [ ! -f "$CLOUD_INIT" ]; then
    echo -e "${RED}Error: $CLOUD_INIT not found!${NC}"
    exit 1
fi

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: 'jq' is not installed. Please install it (sudo apt install jq).${NC}"
    exit 1
fi

# 1. Launch VM
echo -e "${BYELLOW}-> 1. Launching LXD VM '${NC}$VM_NAME${BYELLOW}' (${NC}$IMAGE${BYELLOW}) with CPU: ${NC}$CPU_LIMIT${BYELLOW} cores ; RAM: ${NC}$RAM_LIMIT${BYELLOW} ; DISK: ${NC}$DISK_LIMIT"
echo ""
lxc launch "$IMAGE" "$VM_NAME" --vm --profile $PROFILE -c limits.cpu="$CPU_LIMIT" -c limits.memory="$RAM_LIMIT" --device root,size="$DISK_LIMIT" -c cloud-init.user-data="$(cat "$CLOUD_INIT")"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to launch VM. Exiting.${NC}"
    exit 1
fi

# 2. Watch for IP Address
echo ""
echo -e "${BYELLOW}-> 2. Obtaining IP Address... ${NC}"
echo ""
# Loop until we get an IPv4 address on eth0 (or enp5s0)
IP=""
while [ -z "$IP" ]; do
    IP=$(lxc list "$VM_NAME" --format=json | jq -r '.[0].state.network | to_entries[] | select(.key=="eth0" or .key=="enp5s0") | .value.addresses[] | select(.family=="inet" and .scope=="global") | .address' | head -n 1)
    sleep 2
done
echo "Target IP: $IP"
echo ""
lxc list

# 3. Wait for cloud-init to finish and tail logs
echo ""
echo -e "${BYELLOW}-> 3. Connecting to live Cloud-Init logs... ${NC}"
echo ""

FINISHED=0

while [ $FINISHED -eq 0 ]; do
    # Try to SSH and Tail the log
    ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "ubuntu@$IP" "tail -f /var/log/cloud-init-output.log 2>/dev/null | sed '/finished at/ q'"
    
    # Check why SSH exited
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        # Success! The 'sed' command found the finish line and quit cleanly.
        echo ""
        echo -e "${BYELLOW}Cloud-init finished successfully! ${NC}${CLR_EOL}"
        FINISHED=1
    elif [ $EXIT_CODE -eq 255 ]; then
        # 255 = SSH died (Connection Refused / Network Down / Rebooting)
        echo -ne "${BYELLOW}Connection lost (Rebooting?) retrying... ${NC}${CLR_EOL}\r"
        sleep 3
    else
        # Other errors (file not found yet, etc)
        echo -ne "${BYELLOW}Waiting for log file creation... ${NC}${CLR_EOL}\r"
        sleep 2
    fi
done

# 4. Open dashboard in browser
echo ""
echo -e "${BYELLOW}-> 4. Opening MAAS Dashboard... ${NC}"

# Open Browser
if command -v xdg-open &> /dev/null; then
    xdg-open "http://$IP:5240/MAAS/" > /dev/null 2>&1 &
fi

# 5. Generate Cleanup Script
CLEANUP_SCRIPT="$SCRIPT_DIR/destroy-${VM_NAME}.sh"

cat << EOF > "$CLEANUP_SCRIPT"
#!/bin/bash

echo -e "${BYELLOW}----- Starting Cleanup for $VM_NAME -----${NC}"
echo ""

# 1. Delete the VM
echo -e "${BYELLOW}-> 1. Deleting LXD VM: $VM_NAME... ${NC}"
echo ""
if lxc info "$VM_NAME" >/dev/null 2>&1; then
    
    lxc delete -f "$VM_NAME"
else
    echo -e "VM '$VM_NAME' not found, skipping..."
    echo ""
fi

if [[ "$NO_NEST" == "true" ]]; then
    # 2. Delete the LXD project created by MAAS
    echo -e "${BYELLOW}-> 2. Cleaning up LXD project: $MAAS_PROJECT_NAME... ${NC}"
    echo ""
    if lxc project list | grep -q " $MAAS_PROJECT_NAME "; then
        # Delete all instances inside the $MAAS_PROJECT_NAME project first
        echo "Stopping and deleting all instances in project '$MAAS_PROJECT_NAME'..."
        for inst in \$(lxc list --project $MAAS_PROJECT_NAME --format json | jq -r '.[].name'); do
            lxc delete -f --project $MAAS_PROJECT_NAME "\$inst"
        done

        # Delete all storage volumes inside the $MAAS_PROJECT_NAME project
        echo "Deleting storage volumes in project '$MAAS_PROJECT_NAME'..."
        for vol in \$(lxc storage volume list default --project $MAAS_PROJECT_NAME --format json | jq -r '.[] | select(.type=="custom") | .name'); do
            lxc storage volume delete default "\$vol" --project $MAAS_PROJECT_NAME
        done

        # Delete all images inside the $MAAS_PROJECT_NAME project
        echo "Deleting images in project '$MAAS_PROJECT_NAME'..."
        for img in \$(lxc image list --project $MAAS_PROJECT_NAME --format json | jq -r '.[].fingerprint'); do
            lxc image delete --project $MAAS_PROJECT_NAME "\$img"
        done
        
        # Switch to default to ensure we aren't "inside" the project we are deleting
        lxc project switch default >/dev/null 2>&1
        lxc project delete $MAAS_PROJECT_NAME
        echo ""
    else
        echo "LXD project '$MAAS_PROJECT_NAME' not found, skipping..."
        echo ""
    fi
fi

echo -e "${BYELLOW}----- Cleanup Complete -----${NC}"
rm -- "\$0"
EOF

chmod +x "$CLEANUP_SCRIPT"
echo ""
echo -e "${BYELLOW}-> 5. Cleanup script created: $CLEANUP_SCRIPT ${NC}"

# 6. Final Interactive Shell
echo ""
echo -e "${BYELLOW}-> 6. Dropping into interactive shell... ${NC}"
echo ""
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP"
