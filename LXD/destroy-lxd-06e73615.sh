#!/bin/bash
echo ""
echo -e "\033[1;33m----- Starting Cleanup for LXD Project 'lxd-06e73615' -----\033[0m"
echo ""
echo -e "\033[1;33m-> Cleaning up dedicated LXD project:\033[0m lxd-06e73615"
echo ""
if lxc project list | grep -q "lxd-06e73615"; then
    
    # Delete all instances inside the "lxd-06e73615" project first
    echo "Stopping and deleting all instances in project 'lxd-06e73615'..."
    for inst in $(lxc list --project "lxd-06e73615" --format json | jq -r '.[].name'); do
        lxc stop -f --project "lxd-06e73615" "$inst" 2>/dev/null || true
        sleep 2 # Wait for Ceph/OSD storage locks to release
        lxc delete -f --project "lxd-06e73615" "$inst"
    done
    
    sleep 2 # Buffer to let LXD's database settle before wiping volumes
    
    # Delete all storage volumes inside the "lxd-06e73615" project
    echo "Deleting storage volumes in project 'lxd-06e73615'..."
    for vol in $(lxc storage volume list "default" --project "lxd-06e73615" --format json | jq -r '.[] | select(.type=="custom") | .name'); do
        lxc storage volume delete "default" "$vol" --project "lxd-06e73615"
    done
    
    # Delete all images inside the "lxd-06e73615" project
    echo "Deleting images in project 'lxd-06e73615'..."
    for img in $(lxc image list --project "lxd-06e73615" --format json | jq -r '.[].fingerprint'); do
        lxc image delete --project "lxd-06e73615" "$img"
    done
    
    # Switch to default to ensure we aren't "inside" the project we are deleting
    lxc project switch default 2>/dev/null
    lxc project delete "lxd-06e73615"
else
    echo "LXD project 'lxd-06e73615' not found, skipping..."
fi
echo ""
echo -e "\033[1;33m-> Deleting dynamic bridge:\033[0m lbr-06e73615"
echo ""
if lxc network show "lbr-06e73615" 2>/dev/null; then
    lxc network delete "lbr-06e73615"
else
    echo "Bridge 'lbr-06e73615' not found, skipping..."
fi
echo ""
echo -e "\033[1;33m-> Removing LXD trust for volatile certificate:\033[0m lxd-cert-06e73615"
echo ""
# Fetch the certificate's fingerprint by matching its common name
FINGERPRINT=$(lxc config trust list --format json | jq -r '.[] | select(.name=="lxd-cert-06e73615") | .fingerprint')

if [ -n "$FINGERPRINT" ] && [ "$FINGERPRINT" != "null" ]; then
    lxc config trust remove "$FINGERPRINT"
else
    echo "Certificate 'lxd-cert-06e73615' not found in trust store, skipping..."
    echo ""
fi

rm -f "/home/pablo.degreiff@canonical.com/se-polymerase/LXD/.certs/lxd-cert-06e73615.crt" "/home/pablo.degreiff@canonical.com/se-polymerase/LXD/.certs/lxd-cert-06e73615.key"
if [ -S "/tmp/lxd-ssh-06e73615.sock" ]; then
    echo -e "\033[1;33m-> Cleaning up lingering SSH multiplex socket:\033[0m /tmp/lxd-ssh-06e73615.sock"
    # Send exit command to the master process via the socket to kill the background daemon
    ssh -O exit -o "ControlPath=/tmp/lxd-ssh-06e73615.sock" localhost 2>/dev/null
    rm -f "/tmp/lxd-ssh-06e73615.sock"
    echo ""
fi

echo -e "\033[1;33m-------------- Cleanup Complete --------------\033[0m"

# rm -- "$0" # Self-deletion removed for auditing purposes.
