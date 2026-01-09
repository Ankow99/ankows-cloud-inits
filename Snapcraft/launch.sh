#!/bin/bash

set +e

# Configuration
VM_NAME="${1:-snapcraft}"
IMAGE="ubuntu:24.04"

CLOUD_INIT="./cloud-init/cloud-config.yaml"

CPU_LIMIT="10"
RAM_LIMIT="10GiB"
DISK_LIMIT="50GiB"

CLR_EOL=$'\033[K'

# --- Colors ---
# Check if stderr is a TTY
if [ -t 2 ]; then
    RED='\033[0;31m'
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

# 1. Launch VM
echo -e "${BYELLOW}-> 1. Launching LXD VM '${NC}$VM_NAME${BYELLOW}' (${NC}$IMAGE${BYELLOW}) with CPU: ${NC}$CPU_LIMIT${BYELLOW} cores ; RAM: ${NC}$RAM_LIMIT${BYELLOW} ; DISK: ${NC}$DISK_LIMIT"
echo ""
lxc launch "$IMAGE" "$VM_NAME" --vm -c limits.cpu="$CPU_LIMIT" -c limits.memory="$RAM_LIMIT" --device root,size="$DISK_LIMIT" -c cloud-init.user-data="$(cat "$CLOUD_INIT")"

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
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "ubuntu@$IP" "tail -f /var/log/cloud-init-output.log 2>/dev/null | sed '/finished at/ q'"
    
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

# 4. Final Interactive Shell
echo ""
echo -e "${BYELLOW}-> 4. Dropping into interactive shell... ${NC}"
echo ""
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP"
