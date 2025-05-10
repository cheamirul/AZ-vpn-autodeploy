#!/bin/bash

# --- Configuration ---
RESOURCE_GROUP="vpn-rg-tmp"
LOCATION="southeastasia"
VM_NAME="myvpnserver"
VM_SIZE="Standard_B1s"
ADMIN_USERNAME="azureuser"
SSH_PUBLIC_KEY_PATH="$HOME/.ssh/azure_vpn_rsa.pub" # Make sure this path is correct
VM_IMAGE="Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest"

WIREGUARD_PORT="51820"
VPN_SUBNET="10.0.10.0/24"
SERVER_VPN_IP="10.0.10.1"
CLIENT_VPN_IP="10.0.10.2"
CLIENT_CONFIG_LOCAL_PATH="./wg_client.conf"

# !!! IMPORTANT: USE YOUR CORRECT RAW SCRIPT URL (PASTEBIN OR GIST) !!!
SETUP_SCRIPT_URL="https://gist.githubusercontent.com/cheamirul/b0894c63c308cebd7de298f2fad9695b/raw/fc9dfce4072ced3db32dde4a01d77a0bc154b56c/setup_vpn.sh" # Replace if you use a new/different one

# --- Script ---
echo "Starting VPN Server Deployment..."
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Setup script URL: $SETUP_SCRIPT_URL"

# Basic check for placeholder in URL - update if your actual URL contains these strings
if [[ "$SETUP_SCRIPT_URL" == *"YOUR_USERNAME"* ]] || [[ "$SETUP_SCRIPT_URL" == *"GIST_ID"* ]]; then
    echo "ERROR: Please update SETUP_SCRIPT_URL in the deploy_vpn.sh script with your actual Gist/Pastebin Raw URL."
    exit 1
fi

# Check if the URL is accessible before proceeding
if ! curl --output /dev/null --silent --head --fail "$SETUP_SCRIPT_URL"; then
  echo "ERROR: Cannot access SETUP_SCRIPT_URL: $SETUP_SCRIPT_URL"
  echo "Please check the URL and ensure it's a public raw text link and accessible from your current network."
  exit 1
fi

if [ ! -f "$SSH_PUBLIC_KEY_PATH" ]; then
    echo "Error: SSH public key file not found at $SSH_PUBLIC_KEY_PATH"
    echo "Please generate an SSH key pair or update the SSH_PUBLIC_KEY_PATH variable."
    exit 1
fi

echo "Creating Resource Group: $RESOURCE_GROUP..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o tsv > /dev/null

echo "Creating Static Public IP Address..."
PUBLIC_IP_NAME="${VM_NAME}-pip"
az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PUBLIC_IP_NAME" \
    --sku Basic \
    --allocation-method Static -o tsv > /dev/null
PUBLIC_IP_ADDRESS=$(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" --query ipAddress --output tsv)
echo "Public IP Address: $PUBLIC_IP_ADDRESS"

if [ -z "$PUBLIC_IP_ADDRESS" ]; then
    echo "Error: Failed to retrieve Public IP Address. Exiting."
    exit 1
fi

echo "Creating Network Security Group (NSG)..."
NSG_NAME="${VM_NAME}-nsg"
az network nsg create --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" -o tsv > /dev/null
echo "Allowing SSH on port 22 (optional, for debugging)..."
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "Allow-SSH" --priority 1000 --protocol Tcp --destination-port-ranges 22 --access Allow -o tsv > /dev/null
echo "Allowing WireGuard on UDP port $WIREGUARD_PORT..."
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "Allow-WireGuard" --priority 1010 --protocol Udp --destination-port-ranges "$WIREGUARD_PORT" --access Allow -o tsv > /dev/null
echo "Creating Virtual Network and Subnet..."
VNET_NAME="${VM_NAME}-vnet"
SUBNET_NAME="${VM_NAME}-subnet"
az network vnet create --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" --address-prefix 10.0.0.0/16 --subnet-name "$SUBNET_NAME" --subnet-prefix 10.0.0.0/24 -o tsv > /dev/null
echo "Creating Network Interface..."
NIC_NAME="${VM_NAME}-nic"
az network nic create --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" --network-security-group "$NSG_NAME" --public-ip-address "$PUBLIC_IP_NAME" -o tsv > /dev/null


# Prepare cloud-init script - Add line ending sanitization
CLOUD_INIT_SCRIPT=$(cat <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - curl
  - sed # Ensure sed is available

runcmd:
  - |
    set -e # Exit immediately if a command exits with a non-zero status.
    echo "DEBUG (cloud-init): Entering combined download and execute block."
    echo "DEBUG (cloud-init): curl command: curl -fL ${SETUP_SCRIPT_URL} -o /tmp/setup_vpn.sh"
    if curl -fL "${SETUP_SCRIPT_URL}" -o /tmp/setup_vpn.sh; then
      echo "DEBUG (cloud-init): Download successful."
      if [ ! -s /tmp/setup_vpn.sh ]; then
        echo "ERROR (cloud-init): /tmp/setup_vpn.sh is empty or does not exist after download. Exiting."
        exit 1
      fi
      echo "DEBUG (cloud-init): /tmp/setup_vpn.sh content head (before sanitization):"
      head -n 5 /tmp/setup_vpn.sh
      
      echo "DEBUG (cloud-init): Sanitizing line endings in /tmp/setup_vpn.sh (removing CR characters)..."
      sed -i 's/\r$//' /tmp/setup_vpn.sh
      echo "DEBUG (cloud-init): Line endings sanitized."

      echo "DEBUG (cloud-init): /tmp/setup_vpn.sh content head (after sanitization):"
      head -n 5 /tmp/setup_vpn.sh

      echo "DEBUG (cloud-init): Making setup_vpn.sh executable..."
      chmod +x /tmp/setup_vpn.sh
      
      echo "DEBUG (cloud-init): Adding a small delay..."
      sleep 2

      echo "DEBUG (cloud-init): Executing setup_vpn.sh with bash..."
      if bash /tmp/setup_vpn.sh "${PUBLIC_IP_ADDRESS}" "${SERVER_VPN_IP}" "${WIREGUARD_PORT}" "${CLIENT_VPN_IP}"; then
        echo "DEBUG (cloud-init): setup_vpn.sh executed successfully."
      else
        echo "ERROR (cloud-init): setup_vpn.sh exited with an error code: \$?. Exiting combined block."
        exit 1
      fi
    else
      echo "ERROR (cloud-init): Download failed! curl exit code: \$?. Exiting combined block."
      exit 1
    fi
    echo "DEBUG (cloud-init): Script block finished successfully. Creating cloudinit_done.flag..."
    touch /tmp/cloudinit_done.flag
    echo "DEBUG (cloud-init): cloudinit_done.flag created."
EOF
)

VM_DNS_NAME=$(echo "$VM_NAME" | tr '[:upper:]' '[:lower:]')

echo "Creating VM: $VM_NAME (this may take a few minutes)..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --nics "$NIC_NAME" \
    --admin-username "$ADMIN_USERNAME" \
    --ssh-key-values "$SSH_PUBLIC_KEY_PATH" \
    --custom-data "$CLOUD_INIT_SCRIPT" \
    --public-ip-address-dns-name "$VM_DNS_NAME" \
    -o tsv > /dev/null

echo "VM deployment initiated. Waiting for cloud-init and setup_vpn.sh to complete..."
echo "This can take 5-12 minutes. Please be patient."

FLAG_CHECK_COMMAND="sudo test -f /tmp/cloudinit_done.flag && echo 'done'"
TIMEOUT_SECONDS=720 # 12 minutes
WAIT_INTERVAL=30
ELAPSED_TIME=0
status_output=""
until [[ "$status_output" == *"done"* ]]; do
    if [ $ELAPSED_TIME -ge $TIMEOUT_SECONDS ]; then
        echo "Timeout waiting for cloud-init. Proceeding to get config, but it might not be ready."
        echo "If it fails, you might need to SSH or check cloud-init logs on the VM for errors."
        break
    fi
    echo "Checking cloud-init status on VM... (elapsed: ${ELAPSED_TIME}s)"
    status_output=$(az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --command-id RunShellScript --scripts "$FLAG_CHECK_COMMAND" --query "value[0].message" -o tsv 2>/dev/null)
    sleep $WAIT_INTERVAL
    ELAPSED_TIME=$((ELAPSED_TIME + WAIT_INTERVAL))
done
if [[ "$status_output" == *"done"* ]]; then echo "Cloud-init appears to have completed."; fi

echo "Attempting to retrieve WireGuard client config using Run Command..."
CLIENT_CONFIG_RAW_OUTPUT=$(az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --command-id RunShellScript --scripts "sudo cat /etc/wireguard/client.conf" --query "value[0].message" -o tsv 2>/dev/null)
CLIENT_CONFIG_CONTENT_FORMATTED=""
if [[ -n "$CLIENT_CONFIG_RAW_OUTPUT" ]]; then
    TEMP_CONTENT=$(echo "$CLIENT_CONFIG_RAW_OUTPUT" | awk '/\[stdout\]/{f=1; next} /\[stderr\]/{f=0} f');
    if [[ -n "$TEMP_CONTENT" ]]; then CLIENT_CONFIG_CONTENT_FORMATTED="$TEMP_CONTENT"; else
        CLIENT_CONFIG_CONTENT_FORMATTED=$(echo "$CLIENT_CONFIG_RAW_OUTPUT" | sed -e '1,/\[stdout\]/d' -e '/\[stderr\]/,$d' -e '/^Enable Succeeded:/d' -e '/^$/d');
        if [[ ! "$CLIENT_CONFIG_CONTENT_FORMATTED" == *"[Interface]"* ]] && [[ "$CLIENT_CONFIG_RAW_OUTPUT" == *"[Interface]"* ]]; then CLIENT_CONFIG_CONTENT_FORMATTED="$CLIENT_CONFIG_RAW_OUTPUT"; fi
    fi
    CLIENT_CONFIG_CONTENT_FORMATTED=$(echo "$CLIENT_CONFIG_CONTENT_FORMATTED" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//');
fi
if [[ -n "$CLIENT_CONFIG_CONTENT_FORMATTED" ]] && [[ "$CLIENT_CONFIG_CONTENT_FORMATTED" == *"[Interface]"* ]] && [[ "$CLIENT_CONFIG_CONTENT_FORMATTED" == *"[Peer]"* ]] && [[ "$CLIENT_CONFIG_CONTENT_FORMATTED" == *"PrivateKey ="* ]] && [[ "$CLIENT_CONFIG_CONTENT_FORMATTED" == *"Endpoint ="* ]]; then
    echo "$CLIENT_CONFIG_CONTENT_FORMATTED" > "$CLIENT_CONFIG_LOCAL_PATH"; echo ""; echo "SUCCESS: WireGuard client config saved to: $CLIENT_CONFIG_LOCAL_PATH"; echo "Public IP for VPN Endpoint: $PUBLIC_IP_ADDRESS"; echo "You can now import $CLIENT_CONFIG_LOCAL_PATH into your WireGuard client."; echo "";
else
    echo ""; echo "FAILURE: Failed to retrieve a VALID and COMPLETE client config."; echo "This likely means /etc/wireguard/client.conf on the VM is incomplete or the setup script had an error."; echo "--- Raw output from 'cat /etc/wireguard/client.conf' on VM (before parsing attempt) ---"; echo "$CLIENT_CONFIG_RAW_OUTPUT"; echo "--- Parsed content (attempted extraction) ---"; echo "$CLIENT_CONFIG_CONTENT_FORMATTED"; echo "----------------------------------------------------"; echo "NEXT STEPS:"; echo "1. SSH into the VM: ssh -i $HOME/.ssh/azure_vpn_rsa $ADMIN_USERNAME@$PUBLIC_IP_ADDRESS"; echo "2. Check cloud-init logs (should show download & execution of setup_vpn.sh):"; echo "   sudo cat /var/log/cloud-init-output.log"; echo "   sudo cat /var/log/cloud-init.log | grep -C 5 -i \"failed\" "; echo "3. Check if setup_vpn.sh was downloaded and is not empty: sudo ls -la /tmp/setup_vpn.sh; sudo stat /tmp/setup_vpn.sh"; echo "4. Check its content: sudo cat /tmp/setup_vpn.sh"; echo "5. Try running it manually IF IT EXISTS AND LOOKS OK: sudo bash /tmp/setup_vpn.sh \"${PUBLIC_IP_ADDRESS}\" \"${SERVER_VPN_IP}\" \"${WIREGUARD_PORT}\" \"${CLIENT_VPN_IP}\""; echo "6. Check WireGuard service: sudo systemctl status wg-quick@wg0"; echo "";
fi
echo "Deployment script finished."