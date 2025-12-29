#!/bin/bash
set -euo pipefail

# RustyPanel Caddy Builder
# Caddy is written in Go, so we download the binary or build with xcaddy

CADDY_BRANCH="${VERSION:-latest}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/caddy-build"
INSTALL_PREFIX="/rp/apps/caddy"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Caddy version
CADDY_VERSION="2.9.1"

PACKAGE_NAME="rustypanel-caddy"
PACKAGE_VERSION="${CADDY_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

# Map arch to Go arch
case "$ARCH" in
    amd64) GO_ARCH="amd64" ;;
    arm64) GO_ARCH="arm64" ;;
    *) log_error "Unsupported arch: $ARCH"; exit 1 ;;
esac

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        dpkg-dev \
        fakeroot
}

download_caddy() {
    log_info "Downloading Caddy ${CADDY_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Download official binary (or use xcaddy for custom builds)
    local url="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${GO_ARCH}.tar.gz"
    wget -q "$url" -O caddy.tar.gz
    tar -xzf caddy.tar.gz
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/bin"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # Install Caddy binary
    install -m 755 "${BUILD_DIR}/caddy" "${pkg_dir}${INSTALL_PREFIX}/bin/caddy"

    # Default Caddyfile
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/Caddyfile" << 'EOF'
# RustyPanel Caddy Configuration
# Global options
{
    admin off
    email admin@localhost
    auto_https off
}

# Default site
:80 {
    root * /rp/wwwroot/default
    file_server

    # Logging
    log {
        output file /rp/logs/caddy/access.log
        format json
    }

    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    # Gzip compression
    encode gzip
}
EOF

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-caddy.service" << EOF
[Unit]
Description=RustyPanel Caddy Web Server
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=rustypanel
Group=rustypanel
ExecStart=${INSTALL_PREFIX}/bin/caddy run --config ${INSTALL_PREFIX}/etc/Caddyfile
ExecReload=${INSTALL_PREFIX}/bin/caddy reload --config ${INSTALL_PREFIX}/etc/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # Create default www directory
    mkdir -p "${pkg_dir}/rp/wwwroot/default"
    cat > "${pkg_dir}/rp/wwwroot/default/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>RustyPanel</title>
    <style>
        body { font-family: system-ui, sans-serif; background: #1a1d21; color: #f5f5f4; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .container { text-align: center; }
        h1 { color: #e45a27; }
    </style>
</head>
<body>
    <div class="container">
        <h1>RustyPanel</h1>
        <p>Caddy is running successfully.</p>
    </div>
</body>
</html>
EOF
}

create_debian_control() {
    log_info "Creating Debian control files..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    # Calculate installed size
    local installed_size=$(du -sk "$pkg_dir" | cut -f1)

    # Control file
    cat > "${debian_dir}/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${PACKAGE_VERSION}
Section: web
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${installed_size}
Depends: libc6
Conflicts: caddy
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: Caddy ${CADDY_VERSION} for RustyPanel
 Pre-built Caddy ${CADDY_VERSION} web server.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - Automatic HTTPS with Let's Encrypt
  - HTTP/2 and HTTP/3 support
  - Reverse proxy
  - Simple Caddyfile configuration
  - Zero-downtime reloads
EOF

    # postinst
    cat > "${debian_dir}/postinst" << 'EOF'
#!/bin/bash
set -e

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create directories
mkdir -p /rp/logs/caddy
mkdir -p /rp/wwwroot

chown -R rustypanel:rustypanel /rp/logs/caddy
chown -R rustypanel:rustypanel /rp/wwwroot

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-caddy.service || true

echo "RustyPanel Caddy installed successfully!"
echo "Start with: systemctl start rustypanel-caddy"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

systemctl stop rustypanel-caddy.service || true
systemctl disable rustypanel-caddy.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    rm -rf /rp/apps/caddy
fi

systemctl daemon-reload
EOF
    chmod 755 "${debian_dir}/postrm"
}

build_deb() {
    log_info "Building .deb package..."

    local pkg_dir="${BUILD_DIR}/package"
    local deb_name="${PACKAGE_NAME}_${PACKAGE_VERSION}_${ARCH}.deb"

    cd "$BUILD_DIR"
    dpkg-deb --build --root-owner-group package "${OUTPUT_DIR}/${deb_name}"

    log_success "Package created: ${deb_name}"
}

main() {
    log_info "==================================="
    log_info "RustyPanel Caddy Package Builder"
    log_info "==================================="
    log_info "Caddy Version:  ${CADDY_VERSION}"
    log_info "Distribution:   ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:   ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_caddy
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
