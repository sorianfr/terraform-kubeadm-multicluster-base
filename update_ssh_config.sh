#!/bin/bash

SSH_CONFIG="/mnt/c/Users/soria/.ssh/config"
TEMP_FILE="/mnt/c/Users/soria/.ssh/config.tmp"
WIN_SSH_DIR="/mnt/c/Users/soria/.ssh"
KEY_SOURCE="./k8s-key.pem"
KEY_DEST="$WIN_SSH_DIR/k8s-key.pem"

BASTION_HOST="$1"  # passed from terraform

NEW_ENTRY=$(cat <<EOF
Host bastion
  HostName $BASTION_HOST
  IdentityFile C:/Users/soria/.ssh/k8s-key.pem
  User ubuntu
EOF
)

echo "🔧 Updating SSH config for Bastion..."

# Ensure Windows .ssh directory exists
mkdir -p "$WIN_SSH_DIR"

# Copy key file
if [ -f "$KEY_SOURCE" ]; then
  cp "$KEY_SOURCE" "$KEY_DEST"
  chmod 600 "$KEY_DEST"
  echo "✅ Copied SSH key to Windows and applied permissions"
else
  echo "⚠️ WARNING: $KEY_SOURCE not found — key not copied!"
fi

# Remove old bastion block if exists
if [ -f "$SSH_CONFIG" ]; then
  awk '
    /^Host bastion/ {skip=1}
    /^Host / && !/Host bastion/ {skip=0}
    !skip
  ' "$SSH_CONFIG" > "$TEMP_FILE"
else
  touch "$TEMP_FILE"
fi

# Append new entry
echo -e "\n$NEW_ENTRY" >> "$TEMP_FILE"

# Move back to original config
mv "$TEMP_FILE" "$SSH_CONFIG"

echo "✅ Bastion SSH entry updated:"
echo "$NEW_ENTRY"
