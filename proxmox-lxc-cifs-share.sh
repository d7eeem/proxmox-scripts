#!/bin/bash
#### #### #### #### #### #### #### #### #### #### #### #### #### #### #### #### ####
## -This is a fork from 
## - https://gist.github.com/NorkzYT/14449b247dae9ac81ba4664564669299
## - https://forum.proxmox.com/threads/tutorial-unprivileged-lxcs-mount-cifs-shares.101795/
#### #### #### #### #### #### #### #### #### #### #### #### #### #### #### #### #### ####
# This script is designed to assist in mounting CIFS/SMB shares to a Proxmox LXC container.
# It automates the process of creating a mount point on the Proxmox VE (PVE) host, adding the
# CIFS share to the /etc/fstab for persistent mounts, and configuring the LXC container to
# recognize the share. This script is intended for use on a Proxmox Virtual Environment and
# requires an LXC container to be specified that will access the mounted share.
#
# Prerequisites:
# - Proxmox Virtual Environment setup.
# - An LXC container already created and running on Proxmox.
# - CIFS/SMB share details (hostname/IP, share name, SMB username, and password).
# - Root privileges on the Proxmox host.
#
# How to Use:
# 1. Ensure the target LXC container is running before executing this script.
# 2. Run this script as root or with sudo privileges.
# 3. Follow the prompts to enter the required information for the CIFS/SMB share
#    and the LXC container details.
#
# Note: This script must be run as root to modify system files and perform mount operations.

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Ask user for necessary inputs
read -p "Enter the folder name (e.g., nas_rwx): " folder_name
read -p "Enter the CIFS hostname or IP (e.g., NAS): " cifs_host
read -p "Enter the share name (e.g., media): " share_name
read -p "Enter SMB username: " smb_username
read -sp "Enter SMB password: " smb_password && echo
read -p "Enter the LXC ID: " lxc_id
read -p "Enter the username within the LXC that needs access to the share (e.g., jellyfin, plex): " lxc_username

# Validate permissions format
read -p "Enter the required file permissions (e.g., 0770): " file_permissions
[[ "$file_permissions" =~ ^[0-7]{3,4}$ ]] || { echo "Invalid file permissions format"; exit 1; }

read -p "Enter the required dir permissions (e.g., 0770): " dir_permissions
[[ "$dir_permissions" =~ ^[0-7]{3,4}$ ]] || { echo "Invalid directory permissions format"; exit 1; }

# Validate read-only option
read -p "Is the mount read-only? (Y/n): " read_only
if [[ ! "$read_only" =~ ^[YyNn]$ ]]; then
    echo "Invalid input for read-only option. Please enter Y or N."
    exit 1
fi

# Step 1: Configure LXC
echo "Creating group 'lxc_shares' with GID=10000 in LXC..."
pct exec $lxc_id -- groupadd -g 10000 lxc_shares

echo "Adding user $lxc_username to group 'lxc_shares'..."
pct exec $lxc_id -- usermod -aG lxc_shares $lxc_username

echo "Shutting down the LXC..."
pct stop $lxc_id

# Wait for the LXC to stop
while [ "$(pct status $lxc_id)" != "status: stopped" ]; do
  echo "Waiting for LXC $lxc_id to stop..."
  sleep 1
done

# Step 2: Configure PVE host
echo "Creating mount point on PVE host..."
mkdir -p /mnt/lxc_shares/$folder_name

# Prepare fstab entry
fstab_entry="//${cifs_host}/${share_name} /mnt/lxc_shares/${folder_name} cifs _netdev,x-systemd.automount,noatime,nobrl,uid=100000,gid=110000,dir_mode=${dir_permissions},file_mode=${file_permissions},username=${smb_username},password=${smb_password} 0 0"

# Add to /etc/fstab if not already present
if ! grep -q "//${cifs_host}/${share_name} /mnt/lxc_shares/${folder_name}" /etc/fstab ; then
    echo "Adding CIFS share to /etc/fstab..."
    echo "$fstab_entry" >> /etc/fstab
else
    echo "Entry for ${cifs_host}/${share_name} on /mnt/lxc_shares/${folder_name} already exists."
fi

# Reload systemd and mount the share
echo "Reloading systemd daemon..."
systemctl daemon-reload

if mountpoint -q "/mnt/lxc_shares/$folder_name"; then
    echo "Unmounting the already mounted share to avoid conflicts..."
    umount -l "/mnt/lxc_shares/$folder_name"
fi

echo "Mounting the share on the PVE host..."
mount "/mnt/lxc_shares/$folder_name"

# Add bind mount to LXC config
echo "Determining the next available mount point index..."
config_file="/etc/pve/lxc/${lxc_id}.conf"
if [ -f "$config_file" ]; then
    last_mp_index=$(grep -oP 'mp\d+:' "$config_file" | grep -oP '\d+' | sort -nr | head -n1)
    next_mp_index=$((last_mp_index + 1))
else
    next_mp_index=0
fi

echo "Adding a bind mount of the share to the LXC config..."
if [[ "$read_only" =~ [Yy] ]]; then
   lxc_config_entry="mp${next_mp_index}: /mnt/lxc_shares/${folder_name},mp=/mnt/${folder_name}:ro"
else
   lxc_config_entry="mp${next_mp_index}: /mnt/lxc_shares/${folder_name},mp=/mnt/${folder_name}"
fi
echo "$lxc_config_entry" >> "$config_file"

# Step 3: Start the LXC
echo "Starting the LXC..."
pct start $lxc_id

echo "Configuration complete."
