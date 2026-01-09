#!/bin/bash

set +e

# Configuration
VM_NAME="${1:-ceph}"
IMAGE="ubuntu:24.04"

CLOUD_INIT="./cloud-init/cloud-config.yaml"

CPU_LIMIT="17"
RAM_LIMIT="46GiB"
DISK_LIMIT="280GiB"

CURSOR_TOP='\033[H'
CLEAR_REST='\033[J'
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

# 3. Wait for cloud-init to finish and tail logs and then Juju watch
echo ""
echo -e "${BYELLOW}-> 3. Connecting to live Cloud-Init logs... (Will switch to Juju Status)${NC}"
echo ""

PHASE="LOG_TAIL" 
JUJU_TRIGGER_MSG="-------- Creating Juju Ceph Model... --------"

# Phase options: LOG_TAIL, JUJU_WATCH, DONE

while [ "$PHASE" != "DONE" ]; do

    # PHASE A: LOG TAILING
    if [ "$PHASE" == "LOG_TAIL" ]; then
        # We use sed to quit 'q' if we see the Trigger Message OR "finished at"
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "ubuntu@$IP" "tail -f /var/log/cloud-init-output.log 2>/dev/null | sed '/$JUJU_TRIGGER_MSG/ q; /finished at/ q'"
        
        EXIT_CODE=$?

        if [ $EXIT_CODE -eq 0 ]; then
            # Success! The 'sed' command found the Juju model deploy start and quit cleanly.
            STATUS_CHECK=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "cloud-init status" 2>/dev/null)
            
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

        # Capture both status commands first
        JUJU_OUTPUT=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "juju status --color" 2>/dev/null)
        LOG_OUTPUT=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "tail -n 7 /var/log/cloud-init-output.log" 2>/dev/null)
        SSH_EXIT=$?
        CI_STATUS=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "cloud-init status" 2>/dev/null)

        # Check if we should stop (Is cloud-init done?)
        if [[ "$CI_STATUS" == *"status: done"* ]]; then
            # Print the final status one last time cleanly
            echo -e "${CURSOR_TOP}${BYELLOW}-> 4. Juju Deployment Status (Finalizing...)${NC}${CLR_EOL}"
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
            echo -e "${BYELLOW}-> 4. Juju Deployment Status (Cloud-Init is running...)${NC}${CLR_EOL}"
            echo -e "Target IP: $IP | Updated: $(date +%T)${CLR_EOL}"

            # Tail 5 lines of cloud-init logs
            echo -e "${BYELLOW}--------------------- Latest Logs ---------------------${NC}${CLR_EOL}"
            # Print logs, ensuring we wipe the end of the line for every log entry
            if [ -n "$LOG_OUTPUT" ]; then
                echo -e "$LOG_OUTPUT" | sed "s/$/${CLR_EOL}/"
            else
                echo -e "(Waiting for logs...)${CLR_EOL}"
            fi

            # Juju watch
            echo -e "${BYELLOW}--------------------- Juju Status ---------------------${NC}${CLR_EOL}"
            echo -e "${CLR_EOL}"
            # Print Juju output, ensuring we wipe the end of the line for every log entry
            echo -e "$JUJU_OUTPUT" | sed "s/$/${CLR_EOL}/"
            
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

# 5. Open MAAS dashboard in browser
echo ""
echo -e "${BYELLOW}-> 5. Opening MAAS Dashboard... ${NC}"

# Open Browser
if command -v xdg-open &> /dev/null; then
    xdg-open "http://$IP:5240/MAAS/" > /dev/null 2>&1 &
fi

# 6. Final Interactive Shell
echo ""
echo -e "${BYELLOW}-> 6. Dropping into interactive shell... ${NC}"
echo ""
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP"

