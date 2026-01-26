#!/opt/bin/bash
# Installer for LUKS-encrypted Docker on Asustor NAS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRYPTSETUP="/usr/builtin/bin/cryptsetup"

# Defaults
APP_DIR="/volume1/ssd/.luks_docker"
LUKS_IMG="$APP_DIR/luks_docker.img"
LUKS_MOUNT="/volume1/docker"
LUKS_DEV="dockervault"
LUKS_SIZE="25G"
LUKS_MODE="1"

msg()  { echo "  $1"; }
ok()   { echo "✓ $1"; }
err()  { echo "✗ $1" >&2; }
hdr()  { echo -e "\n=== $1 ===\n"; }

prompt() {
    local var=$1 default=$2 desc=$3 val
    read -rp "$desc [$default]: " val
    eval "$var=\"\${val:-$default}\""
}

check_prereqs() {
    hdr "Checking Prerequisites"
    
    # Check administrators group
    groups | grep -q administrators || { err "Must be in administrators group"; exit 1; }
    ok "User in administrators group"
    
    # Check entware
    [ -x /opt/bin/opkg ] || { err "Entware not installed (install from App Central)"; exit 1; }
    ok "Entware installed"
    
    # Install bash if missing
    if ! command -v bash &>/dev/null; then
        msg "Installing bash..."
        /opt/bin/opkg update && /opt/bin/opkg install bash
    fi
    ok "Bash available"
    
    # Check script-server
    local ss_dir="/volume1/.@plugins/AppCentral/scriptserver/script-server/conf/runners"
    [ -d "$ss_dir" ] || { err "script-server not installed (install from App Central)"; exit 1; }
    ok "script-server installed"
}

get_config() {
    hdr "LUKS Container"
    echo "1) Create NEW LUKS container"
    echo "2) Use EXISTING LUKS container"
    read -rp $'\nSelect [1]: ' LUKS_MODE
    LUKS_MODE="${LUKS_MODE:-1}"
    
    hdr "Configuration"
    msg "Press Enter to accept defaults, or type new values."
    
    prompt APP_DIR "$APP_DIR" "App directory"
    local default_img="$APP_DIR/luks_docker.img"
    prompt LUKS_IMG "$default_img" "LUKS image path"
    
    # Validate based on mode
    if [[ "$LUKS_MODE" == "2" ]]; then
        [ -f "$LUKS_IMG" ] || { err "Existing LUKS image not found: $LUKS_IMG"; exit 1; }
        sudo "$CRYPTSETUP" isLuks "$LUKS_IMG" || { err "Not a valid LUKS container: $LUKS_IMG"; exit 1; }
        ok "Validated existing LUKS container"
        LUKS_SIZE="(existing)"
    else
        [ -f "$LUKS_IMG" ] && { err "File already exists: $LUKS_IMG (remove manually or choose different path)"; exit 1; }
        prompt LUKS_SIZE "$LUKS_SIZE" "LUKS container size"
    fi
    
    prompt LUKS_MOUNT "$LUKS_MOUNT" "Docker mount point"
    prompt LUKS_DEV "$LUKS_DEV" "LUKS device name"
    
    echo -e "\nConfiguration:"
    msg "LUKS_MODE=$([ "$LUKS_MODE" == "1" ] && echo "NEW" || echo "EXISTING")"
    msg "APP_DIR=$APP_DIR"
    msg "LUKS_IMG=$LUKS_IMG"
    msg "LUKS_SIZE=$LUKS_SIZE"
    msg "LUKS_MOUNT=$LUKS_MOUNT"
    msg "LUKS_DEV=$LUKS_DEV"
    
    read -rp $'\nProceed? [Y/n]: ' confirm
    [[ "${confirm:-y}" =~ ^[Yy]$ ]] || exit 0
}

save_config() {
    local app_dir="$APP_DIR/app"
    mkdir -p "$app_dir"
    cat > "$app_dir/asustor-luks-docker-install.log" <<EOF
# Installation config - $(date)
APP_DIR="$APP_DIR"
LUKS_IMG="$LUKS_IMG"
LUKS_MOUNT="$LUKS_MOUNT"
LUKS_DEV="$LUKS_DEV"
EOF
    ok "Config saved to $app_dir/asustor-luks-docker-install.log"
}

# Helper: ensure LUKS is open and mounted
luks_mount() {
    if mountpoint -q "$LUKS_MOUNT"; then
        ok "Already mounted: $LUKS_MOUNT"
        return 0
    fi
    if [ ! -e "/dev/mapper/$LUKS_DEV" ]; then
        msg "Opening LUKS (enter LUKS passphrase, not sudo password)..."
        sudo "$CRYPTSETUP" open "$LUKS_IMG" "$LUKS_DEV"
    fi
    sudo mkdir -p "$LUKS_MOUNT"
    sudo mount -t ext4 "/dev/mapper/$LUKS_DEV" "$LUKS_MOUNT"
    ok "Mounted $LUKS_MOUNT"
}

# Helper: unmount and close LUKS
luks_close() {
    mountpoint -q "$LUKS_MOUNT" && { sudo umount "$LUKS_MOUNT"; msg "Unmounted $LUKS_MOUNT"; }
    [ -e "/dev/mapper/$LUKS_DEV" ] && { sudo "$CRYPTSETUP" close "$LUKS_DEV"; msg "Closed LUKS device"; }
}

create_luks() {
    hdr "LUKS Setup"
    
    if [[ "$LUKS_MODE" == "2" ]]; then
        ok "Using existing LUKS container: $LUKS_IMG"
        return 0
    fi
    
    msg "Creating sparse $LUKS_SIZE file..."
    mkdir -p "$(dirname "$LUKS_IMG")"
    truncate -s "$LUKS_SIZE" "$LUKS_IMG"
    
    msg "Formatting with LUKS..."
    msg "(You will be prompted for a NEW LUKS passphrase - not your sudo password)"
    sudo "$CRYPTSETUP" luksFormat "$LUKS_IMG"
    
    msg "Opening LUKS container (enter the LUKS passphrase you just created)..."
    sudo "$CRYPTSETUP" open "$LUKS_IMG" "$LUKS_DEV"
    
    msg "Creating ext4 filesystem..."
    sudo mkfs.ext4 -L docker_encrypted "/dev/mapper/$LUKS_DEV"
    
    sudo "$CRYPTSETUP" close "$LUKS_DEV"
    ok "LUKS container created"
}

install_docker() {
    hdr "Docker Binaries"
    
    # Get latest version
    local ver
    ver=$(curl -sSL https://api.github.com/repos/moby/moby/releases/latest | \
          sed -n 's/.*"tag_name".*"docker-v\([0-9.]*\)".*/\1/p' | head -1)
    [ -z "$ver" ] && { err "Cannot determine latest Docker version"; exit 1; }
    msg "Latest Docker version: $ver"
    
    luks_mount
    
    # Download and install
    local tmp="/tmp/docker-install-$$"
    mkdir -p "$tmp" && cd "$tmp"
    msg "Downloading Docker $ver..."
    curl --retry 3 --retry-delay 2 -fSL "https://download.docker.com/linux/static/stable/x86_64/docker-${ver}.tgz" -o docker.tgz
    tar -xzf docker.tgz
    
    sudo mkdir -p "$LUKS_MOUNT"/{bin,appdata,lib,config}
    sudo cp docker/* "$LUKS_MOUNT/bin/"
    sudo chmod +x "$LUKS_MOUNT/bin/"*
    
    cd /; rm -rf "$tmp"
    ok "Docker $ver installed to $LUKS_MOUNT/bin"
}

install_configs() {
    hdr "Configuration Files"
    
    local app_dir="$APP_DIR/app"
    mkdir -p "$app_dir/config"
    mkdir -p "$app_dir/templates"
    
    # Copy all repo files, preserving structure
    cp "$SCRIPT_DIR/README.md" "$app_dir/" 2>/dev/null || true
    cp "$SCRIPT_DIR/LICENSE" "$app_dir/" 2>/dev/null || true
    cp "$SCRIPT_DIR/"*.png "$app_dir/" 2>/dev/null || true
    cp "$SCRIPT_DIR/asustor-luks-docker-installer.sh" "$app_dir/" 2>/dev/null || true
    
    # Copy templates directory
    cp -r "$SCRIPT_DIR/templates/"* "$app_dir/templates/" 2>/dev/null || true
    ok "Copied templates"
    
    # daemon.json - edit data-root
    sed "s|__LUKS_MOUNT__|$LUKS_MOUNT|g" "$app_dir/templates/daemon.json" > "$app_dir/config/daemon.json"
    ok "Created daemon.json"
    
    # 90-docker-admin - edit LUKS_MOUNT placeholder
    sed "s|__LUKS_MOUNT__|$LUKS_MOUNT|g" "$app_dir/templates/90-docker-admin" > "$app_dir/config/90-docker-admin"
    ok "Created 90-docker-admin"
    
    # Main script - edit variables
    sed -e "s|DOCKER_DIR:-/volumeX/docker|DOCKER_DIR:-$LUKS_MOUNT|g" \
        -e "s|LUKS_IMG:-/volumeX/yourpath/.docker_luks.img|LUKS_IMG:-$LUKS_IMG|g" \
        -e "s|LUKS_DEV:-dockervault|LUKS_DEV:-$LUKS_DEV|g" \
        "$SCRIPT_DIR/asustor-luks-docker.sh" > "$app_dir/asustor-luks-docker.sh"
    chmod +x "$app_dir/asustor-luks-docker.sh"
    ok "Created asustor-luks-docker.sh"
    
    # script-server runner - edit script path
    sed "s|__APP_DIR__|$app_dir|g" "$app_dir/templates/asustor-luks-docker.json" > "$app_dir/config/asustor-luks-docker.json"
    ok "Created asustor-luks-docker.json"
    
    # Copy to LUKS mount config dir
    luks_mount
    sudo mkdir -p "$LUKS_MOUNT/config"
    sudo cp "$app_dir/config/daemon.json" "$LUKS_MOUNT/config/"
    sudo cp "$app_dir/config/90-docker-admin" "$LUKS_MOUNT/config/"
    ok "Copied configs to LUKS container"
    
    # Install script-server runner
    local ss_dir="/volume1/.@plugins/AppCentral/scriptserver/script-server/conf/runners"
    cp "$app_dir/config/asustor-luks-docker.json" "$ss_dir/"
    ok "Installed script-server runner"
    
    save_config
}

install_portainer() {
    hdr "Portainer Setup"
    
    read -rp "Install Portainer for Docker management? [y/N]: " install_port
    [[ "$install_port" =~ ^[Yy]$ ]] || { msg "Skipping Portainer"; return 0; }
    
    # Port selection
    local random_port=$((30000 + RANDOM % 20000))
    echo ""
    msg "For Portainer, use custom random port or default port?"
    echo ""
    echo "  (1) Custom: $random_port"
    echo "  (2) Default: 9443"
    echo ""
    read -rp "Select [2]: " port_choice
    
    local https_port=9443
    [[ "$port_choice" == "1" ]] && https_port=$random_port
    
    local docker_bin="$LUKS_MOUNT/bin/docker"
    local sock="$LUKS_MOUNT/appdata/docker.sock"
    
    # Start Docker if not running, wait for socket
    if ! pgrep -x dockerd >/dev/null 2>&1; then
        msg "Starting Docker..."
        "$APP_DIR/app/asustor-luks-docker.sh" start "" 2>/dev/null || true
        
        # Wait up to 15 seconds for socket
        local tries=0
        while [ ! -S "$sock" ] && [ $tries -lt 15 ]; do
            sleep 1; ((tries++))
        done
    fi
    
    if [ -S "$sock" ]; then
        msg "Pulling Portainer image..."
        sudo "$docker_bin" --host="unix://$sock" pull portainer/portainer-ce:latest
        
        msg "Creating Portainer container on port $https_port..."
        sudo "$docker_bin" --host="unix://$sock" run -d \
            --name portainer \
            --restart=unless-stopped \
            -p "$https_port:9443" \
            -v "$sock:/var/run/docker.sock" \
            -v "$LUKS_MOUNT/appdata/portainer:/data" \
            portainer/portainer-ce:latest
        
        local ip; ip=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {print $2; exit}' | cut -d/ -f1)
        ok "Portainer installed:"
        msg "  Access at: https://${ip}:${https_port}"
    else
        err "Docker socket not ready after 15s - install Portainer manually after Docker starts"
    fi
}

do_install() {
    check_prereqs
    get_config
    create_luks
    install_docker
    install_configs
    install_portainer

    
    hdr "Installation Complete"
    msg "App directory: $APP_DIR/app"
    msg "Main script: $APP_DIR/app/asustor-luks-docker.sh"
    msg "Run: $APP_DIR/app/asustor-luks-docker.sh start"
    msg "Or use script-server web UI"
}

do_uninstall() {
    hdr "Uninstall"
    
    local log="$APP_DIR/app/asustor-luks-docker-install.log"
    [ -f "$log" ] && source "$log"
    
    msg "This will remove the following, based on the installation log if found or defaults if not:"
    msg "  - $APP_DIR (scripts, configs)"
    msg "  - script-server runner"
    msg "  - $LUKS_MOUNT directory"
    msg "LUKS image ($LUKS_IMG) will NOT be deleted."
    
    read -rp "Continue? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    
    # Stop if running
    pgrep dockerd &>/dev/null && { msg "Stopping Docker..."; "$APP_DIR/app/asustor-luks-docker.sh" shutdown 2>/dev/null || true; }
    
    rm -f "/volume1/.@plugins/AppCentral/scriptserver/script-server/conf/runners/asustor-luks-docker.json"
    rm -rf "$APP_DIR"
    sudo rmdir "$LUKS_MOUNT" 2>/dev/null || true
    
    ok "Uninstalled. LUKS image preserved at $LUKS_IMG"
}

# Main
hdr "Asustor LUKS Docker Installer"
echo "1) Install"
echo "2) Uninstall"
read -rp $'\nSelect [1]: ' choice

case "${choice:-1}" in
    1) do_install ;;
    2) do_uninstall ;;
    *) err "Invalid choice"; exit 1 ;;
esac
