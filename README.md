<p align="center">
  <img src="asustor-luks-docker.png" alt="LUKS Docker">
</p>

# Docker on LUKS-Encrypted Storage for Asustor NAS

Run Docker on LUKS-encrypted storage with web UI management via script-server.

## Why?

Asustor's App Central Docker is unencrypted. Even if you store Docker data in an encrypted Shared Folder, your metadata, images, etc. are all exposed—anyone with access can see and manipulate what you're running.

**For LUKS container management without Docker**, see [asustor-luks-manager](https://github.com/gooselabz/asustor-luks-manager).

## Key Challenges Overcome

- **Bash Works Better**: ADM defaults to BusyBox; install bash from Entware.
- **ext4 Works Better**: Store your LUKS container on ext4, not btrfs.
- **pivot_root Fails on LUKS**: Set `DOCKER_RAMDISK=true` to use chroot instead (no RAM penalty).
- **Web GUI Works Better**: For typical use (e.g., after reboot), script-server provides a simple web interface.

## Setup

### 1. Prerequisites

- **Entware**: Install from App Central
- **script-server**: Install from App Central
- **Recommended**: Use or create an encrypted Shared Folder for the app and LUKS image (Preferences → Shared Folders). By default the installer uses Shared Folder `ssd` on `volume1`, but this can be customized during install.

### 2. Run the Interactive Installer

```bash
# Clone or download the repo
git clone https://github.com/gooselabz/asustor-luks-docker.git
cd asustor-luks-docker

# Run installer
./asustor-luks-docker-installer.sh
```

The installer will:
- Create or use an existing LUKS container
- Download and install Docker binaries
- Configure sudoers for passwordless operation
- Set up script-server web UI
- Optionally install Portainer

## Usage

### Web UI (script-server)

1. Navigate to `http://YOUR_NAS_IP:SCRIPT-SERVER-PORT`
2. Click **Asustor LUKS Docker** in left menu
3. Select action: `start`, `shutdown`, `status`, or `update`
4. For start: Enter passphrase in secure field
5. Execute

### Command Line

```bash
# Start Docker (prompts for passphrase)
/path/to/asustor-luks-docker.sh start

# Start with passphrase (non-interactive)
/path/to/asustor-luks-docker.sh start "your-passphrase"

# Shutdown (stops containers gracefully)
/path/to/asustor-luks-docker.sh shutdown

# Status
/path/to/asustor-luks-docker.sh status

# Update Docker binaries
/path/to/asustor-luks-docker.sh update          # Latest version
/path/to/asustor-luks-docker.sh update 29.1.3   # Specific version
```

## Security Notes

- **No keyfiles**: Passphrase required every mount—no keys stored on device
- Security = passphrase strength
- Sudoers allows passwordless operations—restrict to trusted users only
- Docker containers auto-start with `restart: unless-stopped` policy (recommended)

## Uninstall

```bash
./asustor-luks-docker-installer.sh
# Select "Uninstall"
```

The LUKS image is preserved; only scripts and configs are removed.

## Related Projects

- [asustor-luks-manager](https://github.com/gooselabz/asustor-luks-manager) - General LUKS container management

## License

MIT License - see [LICENSE](LICENSE) file
