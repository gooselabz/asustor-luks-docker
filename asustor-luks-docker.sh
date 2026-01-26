#!/opt/bin/bash
# LUKS-encrypted Docker for Asustor NAS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/bin:/opt/sbin:/usr/builtin/bin:/usr/builtin/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Load config from install log if present, else use defaults
CONFIG_FILE="$SCRIPT_DIR/asustor-luks-docker-install.log"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
LUKS_MOUNT="${LUKS_MOUNT:-/volume1/docker}"
LUKS_IMG="${LUKS_IMG:-/volume1/ssd/.luks_docker/luks_docker.img}"
LUKS_DEV="${LUKS_DEV:-dockervault}"

# Derived paths
BIN="$LUKS_MOUNT/bin"
DATA="$LUKS_MOUNT/appdata"
SOCK="$DATA/docker.sock"
export PATH="$BIN:$PATH"

# Helpers
msg() { echo "  $1"; }
ok()  { echo "✓ $1"; }
err() { echo "✗ $1" >&2; }
hdr() { echo -e "\n=== $1 ===\n"; }

is_mounted() { mountpoint -q "$LUKS_MOUNT" 2>/dev/null; }
is_running() { pgrep "$1" >/dev/null 2>&1; }
docker_cmd() { "$BIN/docker" --host="unix://$SOCK" "$@"; }

stop_proc() {
    local name=$1
    is_running "$name" || return 1
    sudo pkill -TERM "$name" 2>/dev/null; sleep 2
    is_running "$name" && sudo pkill -9 "$name" 2>/dev/null
    return 0
}

sync_configs() {
    local cfg="$LUKS_MOUNT/config"
    [ -f "$cfg/daemon.json" ] && { sudo mkdir -p /etc/docker; sudo cp "$cfg/daemon.json" /etc/docker/; }
    [ -f "$cfg/90-docker-admin" ] && { sudo cp "$cfg/90-docker-admin" /etc/sudoers.d/; sudo chmod 0440 /etc/sudoers.d/90-docker-admin; }
}

mount_cgroups() {
    mountpoint -q /sys/fs/cgroup 2>/dev/null && return 0
    sudo mount -t tmpfs cgroup_root /sys/fs/cgroup
    for s in cpuset cpu cpuacct blkio memory devices freezer net_cls perf_event net_prio pids; do
        sudo mkdir -p /sys/fs/cgroup/$s && sudo mount -t cgroup -o $s cgroup /sys/fs/cgroup/$s 2>/dev/null || true
    done
}

cmd_start() {
    local pass="${1:-}"
    hdr "Starting Docker"
    
    is_mounted && is_running dockerd && { ok "Already running"; return 0; }
    
    # Mount if needed
    if ! is_mounted; then
        [ -e "/dev/mapper/$LUKS_DEV" ] || {
            [ -z "$pass" ] && { err "LUKS passphrase required"; return 1; }
            msg "Unlocking LUKS..."
            echo "$pass" | sudo cryptsetup open "$LUKS_IMG" "$LUKS_DEV" - || { err "Unlock failed"; return 1; }
            ok "LUKS unlocked"
        }
        sudo mkdir -p "$LUKS_MOUNT"
        sudo mount -t ext4 "/dev/mapper/$LUKS_DEV" "$LUKS_MOUNT" || { sudo cryptsetup close "$LUKS_DEV"; err "Mount failed"; return 1; }
        ok "Mounted $LUKS_MOUNT"
    fi
    
    sync_configs
    mount_cgroups

    # Start daemons
    msg "Starting containerd..."
    sudo -b "$BIN/containerd" --state "$DATA/containerd/state" --root "$DATA/containerd/root" \
        --address "$DATA/containerd/containerd.sock" >>"$DATA/containerd.log" 2>&1
    sleep 2
    is_running containerd || { err "containerd failed"; return 1; }
    ok "containerd started"
    
    msg "Starting dockerd..."
    sudo -b env PATH="$PATH" DOCKER_RAMDISK=true "$BIN/dockerd" --exec-root="$DATA/run" --pidfile="$DATA/dockerd.pid" \
        --host="unix://$SOCK" --containerd="$DATA/containerd/containerd.sock" >>"$DATA/dockerd.log" 2>&1
    sleep 3
    docker_cmd info >/dev/null 2>&1 || { err "dockerd failed - check $DATA/dockerd.log"; return 1; }
    
    # Create symlink for default docker CLI
    sudo ln -sf "$SOCK" /var/run/docker.sock
    
    hdr "Docker Ready"
    msg "Socket: $SOCK"
}

cmd_shutdown() {
    hdr "Shutting Down"
    
    stop_proc containerd-shim && ok "shims stopped"
    stop_proc dockerd && ok "dockerd stopped" || msg "dockerd not running"
    stop_proc containerd && ok "containerd stopped" || msg "containerd not running"
    
    if is_mounted; then
        sync; sleep 1
        sudo umount "$LUKS_MOUNT" 2>/dev/null || sudo umount -l "$LUKS_MOUNT" || { err "Unmount failed"; return 1; }
        ok "Unmounted"
    fi
    
    [ -e "/dev/mapper/$LUKS_DEV" ] && { sudo cryptsetup close "$LUKS_DEV" && ok "LUKS closed"; }
    hdr "Shutdown Complete"
}

cmd_status() {
    hdr "Status"
    echo "Mount:"; is_mounted && { ok "$LUKS_MOUNT"; df -h "$LUKS_MOUNT" | tail -1; } || msg "Not mounted"
    echo "containerd:"; is_running containerd && ok "Running" || msg "Stopped"
    echo "dockerd:"; is_running dockerd && ok "Running" || msg "Stopped"
    is_running dockerd && { echo -e "\nContainers:"; docker_cmd ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true; }
    [ -f "$BIN/dockerd" ] && { echo -e "\nVersion:"; msg "$("$BIN/dockerd" --version 2>/dev/null | awk '{print $3}' | tr -d ',')"; }
}

cmd_update() {
    local ver="${1:-}"
    hdr "Update"
    
    [ -d "$BIN" ] || { err "Docker not installed"; return 1; }
    local cur; cur=$("$BIN/dockerd" --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "unknown")
    msg "Current: $cur"
    
    [ -z "$ver" ] && ver=$(curl -sSL https://api.github.com/repos/moby/moby/releases/latest | sed -n 's/.*"tag_name".*"v\([0-9.]*\)".*/\1/p' | head -1)
    [ -z "$ver" ] && { err "Cannot determine latest version"; return 1; }
    [ "$cur" = "$ver" ] && { ok "Already at $ver"; return 0; }
    
    local tmp="/tmp/docker-update-$$" backup="$LUKS_MOUNT/bin-backup-$(date +%Y%m%d%H%M%S)"
    trap "rm -rf '$tmp'" EXIT
    mkdir -p "$tmp" && cd "$tmp"
    
    msg "Downloading $ver..."
    curl --retry 3 -fSL "https://download.docker.com/linux/static/stable/x86_64/docker-${ver}.tgz" -o docker.tgz || { err "Download failed"; return 1; }
    tar -xzf docker.tgz
    
    stop_proc dockerd; stop_proc containerd
    sudo cp -a "$BIN" "$backup" && ok "Backup: $backup"
    sudo cp -f docker/* "$BIN/" && sudo chmod +x "$BIN"/*
    ok "Installed $ver - run 'start' to restart"
}

case "${1:-status}" in
    start)    cmd_start "${2:-}" ;;
    stop|shutdown) cmd_shutdown ;;
    status)   cmd_status ;;
    update)   cmd_update "${2:-}" ;;
    *) echo "Usage: $0 {start|shutdown|status|update} [args]"; exit 1 ;;
esac
