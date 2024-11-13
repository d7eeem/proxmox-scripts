#!/bin/bash
#### #### #### #### #### #### #### #### #### #### #### #### #### #### #### #### ####
## -This is a fork from 
## - https://gist.github.com/NorkzYT/14449b247dae9ac81ba4664564669299
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
# Create mount point
echo "Creating mount point on PVE host..."
mkdir -p /mnt/lxc_shares/$folder_name

# Check if the fstab entry exists
fstab_entry="//${cifs_host}/${share_name} /mnt/lxc_shares/${folder_name} cifs _netdev,x-systemd.automount,noatime,nobrl,uid=100000,gid=110000,dir_mode=0770,file_mode=0770,username=${smb_username},password=${smb_password} 0 0"
if ! grep -q "//${cifs_host}/${share_name} /mnt/lxc_shares/${folder_name}" /etc/fstab ; then
    echo "Adding NAS CIFS share to /etc/fstab with nobrl option..."
    echo "$fstab_entry" >> /etc/fstab
else
    echo "Entry for ${cifs_host}/${share_name} on /mnt/lxc_shares/${folder_name} already exists in /etc/fstab."
fi

# Reload systemd to recognize changes to fstab
echo "Reloading systemd daemon to apply fstab changes..."
systemctl daemon-reload

# Before mounting, ensure the mount point is not already in use
if mountpoint -q "/mnt/lxc_shares/$folder_name"; then
    echo "Unmounting the already mounted share to avoid conflicts..."
    umount -l "/mnt/lxc_shares/$folder_name"
fi

# Mount the share
echo "Mounting the share on the PVE host..."
mount "/mnt/lxc_shares/$folder_name"

# Add a bind mount of the share to the LXC config
echo "Determining the next available mount point index..."
config_file="/etc/pve/lxc/${lxc_id}.conf"
if [ -f "$config_file" ]; then
    last_mp_index=$(grep -oP 'mp\d+:' "$config_file" | grep -oP '\d+' | sort -nr | head -n1)
    next_mp_index=$((last_mp_index + 1))
else
    next_mp_index=0
fi

echo "Adding a bind mount of the share to the LXC config..."
lxc_config_entry="mp${next_mp_index}: /mnt/lxc_shares/${folder_name},mp=/mnt/${folder_name}"
echo "$lxc_config_entry" >> "$config_file"

# Step 3: Start the LXC
echo "Starting the LXC..."
pct start $lxc_id

echo "Configuration complete."
