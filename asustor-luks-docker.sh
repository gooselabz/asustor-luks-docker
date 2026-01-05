#!/opt/bin/bash
# LUKS-encrypted Docker for Asustor NAS
# Usage: asustor_luks_docker.sh {start|shutdown|update|status} [args]
set -euo pipefail

# Config - Edit these for your setup
readonly DOCKER_DIR="${DOCKER_DIR:-/volumeX/docker}"
readonly BIN="${DOCKER_DIR}/bin"
readonly DATA="${DOCKER_DIR}/appdata"
readonly LUKS_IMG="${LUKS_IMG:-/volumeX/yourpath/.docker_luks.img}"
readonly LUKS_DEV="${LUKS_DEV:-dockervault}"
readonly PORTAINER_PORT="${PORTAINER_PORT:-9443}"

# Helpers
msg()  { echo "  $1"; }
ok()   { echo "✓ $1"; }
err()  { echo "✗ $1" >&2; }
warn() { echo "⚠ $1"; }
hdr()  { echo -e "\n=== $1 ===\n"; }

is_mounted()  { mountpoint -q "$DOCKER_DIR"; }
pgrep_safe()  { pgrep "$1" >/dev/null 2>&1; }

docker_cmd() { PATH="$BIN:$PATH" docker --host="unix://$DATA/docker.sock" "$@"; }

stop_proc() {
    local name=$1 wait=${2:-3}
    pgrep_safe "$name" || return 1  # Not running
    sudo pkill -TERM "$name" 2>/dev/null || true
    sleep "$wait"
    pgrep_safe "$name" && sudo pkill -KILL "$name" 2>/dev/null || true
    return 0
}

# Start: unlock LUKS, mount, start daemons
cmd_start() {
    local pass="${1:-}"
    [ "$pass" = "" ] && pass=""  # Normalize empty string
    hdr "Starting Docker"

    # Already running?
    if is_mounted && pgrep_safe dockerd; then
        ok "Docker already running"; return 0
    fi

    # Unlock & mount if needed
    if ! is_mounted; then
        if [ ! -e "/dev/mapper/$LUKS_DEV" ]; then
            if [ -z "$pass" ]; then
                err "LUKS passphrase required for start command"
                return 1
            fi
            msg "Unlocking LUKS..."
            echo "$pass" | sudo /usr/builtin/bin/cryptsetup open "$LUKS_IMG" "$LUKS_DEV" - || { err "Unlock failed"; return 1; }
            unset pass
            ok "LUKS unlocked"
        fi
        
        msg "Mounting LUKS Container..."
        sudo mount -t ext4 "/dev/mapper/$LUKS_DEV" "$DOCKER_DIR" || { 
            sudo /usr/builtin/bin/cryptsetup close "$LUKS_DEV"; err "Mount failed"; return 1
        }
        ok "Mounted $DOCKER_DIR"
    else
        warn "Already mounted, skipping LUKS"
    fi

    # Start containerd
    msg "Starting containerd..."
    sudo -b sh -c "PATH=$BIN:/usr/builtin/sbin:\$PATH $BIN/containerd \
        --state $DATA/containerd/state --root $DATA/containerd/root \
        --address $DATA/containerd/containerd.sock >>$DATA/containerd.log 2>&1"
    sleep 2
    pgrep_safe containerd && ok "containerd (PID $(pgrep containerd | head -1))" || { err "containerd failed"; return 1; }

    # Start dockerd with pivot_root workaround
    msg "Starting dockerd..."
    sudo -b sh -c "PATH=$BIN:/usr/builtin/sbin:\$PATH DOCKER_RAMDISK=true $BIN/dockerd \
        --exec-root=$DATA/run --pidfile=$DATA/dockerd.pid \
        --host=unix://$DATA/docker.sock --containerd=$DATA/containerd/containerd.sock \
        >>$DATA/dockerd.log 2>&1"
    sleep 4
    docker_cmd ps >/dev/null 2>&1 && ok "dockerd running" || { err "dockerd failed - check $DATA/dockerd.log"; return 1; }

    local ip; ip=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {print $2; exit}' | cut -d/ -f1)
    hdr "Docker Ready"
    msg "Portainer: https://${ip}:${PORTAINER_PORT}"
}

# Shutdown: stop daemons, unmount, close LUKS
cmd_shutdown() {
    hdr "Shutting Down Docker"

    stop_proc dockerd 3 && ok "dockerd stopped" || msg "dockerd not running"
    stop_proc containerd 2 && ok "containerd stopped" || msg "containerd not running"

    if is_mounted; then
        msg "Unmounting..."
        sudo umount "$DOCKER_DIR" 2>/dev/null || sudo umount -l "$DOCKER_DIR" || { err "Unmount failed"; return 1; }
        sync
        sleep 1
        ok "Unmounted"
    else
        msg "Not mounted"
    fi

    if [ -e "/dev/mapper/$LUKS_DEV" ]; then
        msg "Closing LUKS..."
        sudo /usr/builtin/bin/cryptsetup close "$LUKS_DEV" || { err "LUKS close failed"; return 1; }
        ok "LUKS closed"
    fi

    hdr "Shutdown Complete"
}

# Status: show LUKS, mount, daemon, container info
cmd_status() {
    hdr "Docker Status"

    echo "LUKS Mount:"; is_mounted && { ok "Mounted"; df -h "$DOCKER_DIR" | tail -1; } || msg "Not mounted"
    echo "containerd:"; pgrep_safe containerd && ok "Running (PID $(pgrep containerd | head -1))" || msg "Stopped"
    echo "dockerd:"; pgrep_safe dockerd && ok "Running (PID $(pgrep dockerd))" || msg "Stopped"

    if pgrep_safe dockerd; then
        echo -e "\nContainers:"
        docker_cmd ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || msg "Unable to query"
    fi

    echo -e "\nVersions:"
    [ -f "$BIN/dockerd" ] && msg "Docker: $("$BIN/dockerd" --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    [ -f "$BIN/containerd" ] && msg "containerd: $("$BIN/containerd" --version 2>/dev/null | awk '{print $3}')"
    [ -f "$BIN/runc" ] && msg "runc: $("$BIN/runc" --version 2>/dev/null | awk 'NR==1{print $3}')"
}

# Update: download and install Docker binaries
cmd_update() {
    local ver="${1:-}" url backup
    [ "$ver" = "" ] && ver=""  # Treat empty string as unset
    local tmp="$DOCKER_DIR/tmp-update"
    backup="$DOCKER_DIR/bin-backup-$(date +%Y%m%d%H%M%S)"
    trap "rm -rf '$tmp' 2>/dev/null || true" RETURN
    hdr "Docker Update"

    [ -d "$BIN" ] || { err "Docker not installed at $BIN"; return 1; }

    local cur; cur=$("$BIN/dockerd" --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "unknown")
    msg "Current: $cur"

    # Get version
    if [ -z "$ver" ]; then
        ver=$(curl -sSL https://api.github.com/repos/moby/moby/releases/latest 2>/dev/null | sed -n 's/.*"tag_name".*"docker-v\([0-9.]*\)".*/\1/p' | head -1)
        [ -z "$ver" ] && { msg "Cannot fetch latest - specify version manually"; return 0; }
        msg "Latest: $ver"
    fi

    [ "$cur" = "$ver" ] && { ok "Already at $ver"; return 0; }

    # Download & extract
    url="https://download.docker.com/linux/static/stable/x86_64/docker-${ver}.tgz"
    msg "Downloading $ver..."
    mkdir -p "$tmp" && cd "$tmp"
    curl -fSL "$url" -o docker.tgz || { err "Download failed: $url"; return 1; }
    tar -xzf docker.tgz && [ -d docker ] || { err "Extraction failed"; return 1; }
    ok "Downloaded $(du -h docker.tgz | awk '{print $1}')"

    # Confirm
    local new; new=$(./docker/dockerd --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    msg "New version: $new"

    # Stop, backup, install (non-interactive for script-server)
    stop_proc dockerd 2; stop_proc containerd 2
    sudo cp -a "$BIN" "$backup" && ok "Backup: $backup"
    sudo cp -f docker/* "$BIN/" && sudo chmod +x "$BIN"/*
    ok "Installed $new"

    hdr "Update Complete"
    msg "Run 'asustor_luks_docker.sh start' to restart"
    msg "Rollback: sudo rm -rf $BIN && sudo mv $backup $BIN"
}

# Help
cmd_help() {
    cat <<'EOF'
Docker Admin - LUKS-encrypted Docker for Asustor NAS

Usage: asustor_luks_docker.sh <command> [args]

Commands:
  start [pass]   Unlock LUKS, mount, start Docker (prompts if no pass)
  shutdown       Stop Docker, unmount, close LUKS (alias: stop)
  status         Show LUKS/Docker status
  update [ver]   Update Docker binaries (prompts for version)
  help           This message

Examples:
  asustor_luks_docker.sh start
  asustor_luks_docker.sh shutdown
  asustor_luks_docker.sh status
  asustor_luks_docker.sh update 29.1.3
EOF
}
# Main
case "${1:-status}" in
    start)    shift; cmd_start "$@" ;;
    stop|shutdown) cmd_shutdown ;;
    status)   cmd_status ;;
    update)   shift; cmd_update "$@" ;;
    *) err "Unknown: $1"; exit 1 ;;
esac
