#!/bin/bash

set +e

# Configuration
VM_NAME="landscape-server"
IMAGE="ubuntu:24.04"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

CLOUD_INIT="$SCRIPT_DIR/cloud-init/cloud-config-server.yaml"
CLOUD_INIT_CLIENT="$SCRIPT_DIR/cloud-init/cloud-config-client.yaml"
CLOUD_INIT_HA="$SCRIPT_DIR/cloud-init/cloud-config-ha.yaml"
CLOUD_INIT_HA_NN="$SCRIPT_DIR/cloud-init/cloud-config-ha-nn.yaml"

CPU_LIMIT="2"
RAM_LIMIT="6GiB"
DISK_LIMIT="20GiB"

CURSOR_TOP='\033[H'
CLEAR_REST='\033[J'
CLR_EOL=$'\033[K'

CLIENT_MODE=false
HA_MODE=false
NO_NEST=false
PROFILE="default"
MAAS_PROJECT_NAME="maas"
CUSTOM_NAME_SET=false

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --client)
            CLIENT_MODE=true
            shift 1
            ;;
        --ha)
            HA_MODE=true
            shift 1
            ;;
        --nn)
            NO_NEST=true
            HA_MODE=true
            shift 1
            ;;
        *)
            VM_NAME="$1"
            CUSTOM_NAME_SET=true
            shift 1
            ;;
    esac
done

if [ "$HA_MODE" = true ] && [ "$NO_NEST" = true ]; then
    echo -e "${BYELLOW}-> Switch enabled: Using HA non nested LXD cloud-init config. ${NC}"
    echo ""
    CLOUD_INIT="$CLOUD_INIT_HA_NN"
    if [ "$CUSTOM_NAME_SET" = false ]; then
        VM_NAME="landscape-ha"
    fi
    CPU_LIMIT="2"
    RAM_LIMIT="6GiB"
    DISK_LIMIT="20GiB"
    PROFILE="maas"

elif [ "$HA_MODE" = true ]; then
    echo -e "${BYELLOW}-> Switch enabled: Using HA cloud-init config. ${NC}"
    echo ""
    CLOUD_INIT="$CLOUD_INIT_HA"
    if [ "$CUSTOM_NAME_SET" = false ]; then
        VM_NAME="landscape-ha"
    fi
    CPU_LIMIT="15"
    RAM_LIMIT="38GiB"
    DISK_LIMIT="170GiB"

elif [ "$CLIENT_MODE" = true ]; then
    echo -e "${BYELLOW}-> Switch enabled: Using client cloud-init config. ${NC}"
    echo ""
    CLOUD_INIT="$CLOUD_INIT_CLIENT"
    if [ "$CUSTOM_NAME_SET" = false ]; then
        VM_NAME="landscape-client"
    fi
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

if [ "$HA_MODE" == "false" ]; then
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
    echo -e "${BYELLOW}-> 4. Opening Landscape Dashboard... ${NC}"

    # Open Browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "https://$IP" > /dev/null 2>&1 &
    fi

    # 5. Final Interactive Shell
    echo ""
    echo -e "${BYELLOW}-> 5. Dropping into interactive shell... ${NC}"
    echo ""
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP"

else

    # 3. Wait for cloud-init to finish and tail logs and then Juju watch
    echo ""
    echo -e "${BYELLOW}-> 3. Connecting to live Cloud-Init logs... (Will switch to Juju Status)${NC}"
    echo ""

    PHASE="LOG_TAIL" 
    JUJU_TRIGGER_MSG="-------- Creating Juju Landscape Model... --------"
    
    # Phase options: LOG_TAIL, JUJU_WATCH, DONE

    while [ "$PHASE" != "DONE" ]; do

        # PHASE A: LOG TAILING
        if [ "$PHASE" == "LOG_TAIL" ]; then
            # We use sed to quit 'q' if we see the Trigger Message OR "finished at"
            ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "ubuntu@$IP" "tail -f /var/log/cloud-init-output.log 2>/dev/null | sed '/$JUJU_TRIGGER_MSG/ q; /finished at/ q'"
            
            EXIT_CODE=$?

            if [ $EXIT_CODE -eq 0 ]; then
                # Success! The 'sed' command found the Juju model deploy start and quit cleanly.
                STATUS_CHECK=$(ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "cloud-init status" 2>/dev/null)
                
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
            JUJU_OUTPUT=$(ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "juju status --color" 2>/dev/null)
            LOG_OUTPUT=$(ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "tail -n 7 /var/log/cloud-init-output.log" 2>/dev/null)
            SSH_EXIT=$?
            CI_STATUS=$(ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "cloud-init status" 2>/dev/null)

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

    if [[ "$NO_NEST" == "false" ]]; then
        # 5. Set ip route
        echo ""
        echo -e "${BYELLOW}-> 5. Setting IP route for Landscape Dashboard... ${NC}"
        echo ""

        sudo ip r add 10.10.20.0/24 via $IP dev lxdbr0 || true
    fi

    # 6. Obtain HAProxy IP
    echo ""
    echo -e "${BYELLOW}-> 6. Obtaining HAProxy Leader IP... ${NC}"
    echo ""

    HAPROXY_IP=$(ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP" "juju exec --unit haproxy/leader -- unit-get public-address" 2>/dev/null)

    echo "HAProxy Leader IP: $HAPROXY_IP"

    # 7. Open dashboard in browser
    echo ""
    echo -e "${BYELLOW}-> 7. Opening Landscape Dashboard... ${NC}"

    # Open Browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "https://$HAPROXY_IP" > /dev/null 2>&1 &
    fi

    # 8. Open MAAS dashboard in browser
    echo ""
    echo -e "${BYELLOW}-> 8. Opening MAAS Dashboard... ${NC}"

    # Open Browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "http://$IP:5240/MAAS/" > /dev/null 2>&1 &
    fi

    # 9. Generate Cleanup Script
    CLEANUP_SCRIPT="./destroy-${VM_NAME}.sh"

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
        
        # Switch to default to ensure we aren't "inside" the project we are deleting
        lxc project switch default >/dev/null 2>&1
        lxc project delete $MAAS_PROJECT_NAME
        echo ""
    else
        echo "LXD project '$MAAS_PROJECT_NAME' not found, skipping..."
        echo ""
    fi
else
    sudo ip r del 10.10.20.0/24 via $IP dev lxdbr0
fi

echo -e "${BYELLOW}----- Cleanup Complete -----${NC}"
rm -- "\$0"
EOF

    chmod +x "$CLEANUP_SCRIPT"
    echo ""
    echo -e "${BYELLOW}-> 9. Cleanup script created: $CLEANUP_SCRIPT ${NC}"


    # 10. Final Interactive Shell
    echo ""
    echo -e "${BYELLOW}-> 10. Dropping into interactive shell... ${NC}"
    echo ""
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@$IP"
fi
