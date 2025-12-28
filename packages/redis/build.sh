#!/bin/bash
set -euo pipefail

# RustyPanel Redis Builder

REDIS_BRANCH="${VERSION:-8.0}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/redis-build"
INSTALL_PREFIX="/rp/apps/redis"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Redis version mapping
declare -A REDIS_VERSIONS=(
    ["8.0"]="8.0.1"
    ["7.4"]="7.4.2"
    ["7.2"]="7.2.7"
)

REDIS_VERSION="${REDIS_VERSIONS[$REDIS_BRANCH]:-}"
if [[ -z "$REDIS_VERSION" ]]; then
    log_error "Unknown Redis branch: $REDIS_BRANCH"
    exit 1
fi

REDIS_VERSION_SHORT="${REDIS_BRANCH//./}"
PACKAGE_NAME="rustypanel-redis${REDIS_VERSION_SHORT}"
PACKAGE_VERSION="${REDIS_VERSION}-1"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        pkg-config \
        libssl-dev \
        libsystemd-dev \
        dpkg-dev \
        fakeroot
}

download_redis() {
    log_info "Downloading Redis ${REDIS_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    wget -q "https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz" -O redis.tar.gz
    tar -xzf redis.tar.gz
    cd "redis-${REDIS_VERSION}"
}

build_redis() {
    log_info "Building Redis..."

    make -j"$(nproc)" \
        PREFIX="${INSTALL_PREFIX}" \
        BUILD_TLS=yes \
        USE_SYSTEMD=yes
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

    # Install Redis
    make PREFIX="${pkg_dir}${INSTALL_PREFIX}" install

    # Redis config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/redis.conf" << EOF
# RustyPanel Redis ${REDIS_BRANCH} Configuration

# Network
bind 127.0.0.1 -::1
port 6379
unixsocket /run/rustypanel/redis-${REDIS_BRANCH}.sock
unixsocketperm 770
protected-mode yes

# General
daemonize no
pidfile /run/rustypanel/redis-${REDIS_BRANCH}.pid
loglevel notice
logfile /rp/logs/redis/redis-${REDIS_BRANCH}.log

# Data
dir /rp/data/redis/${REDIS_BRANCH}
dbfilename dump.rdb

# Snapshotting
save 900 1
save 300 10
save 60 10000

# Memory
maxmemory 256mb
maxmemory-policy allkeys-lru

# Append Only File
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# Security
# requirepass your_password_here

# Limits
maxclients 10000
EOF

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-redis${REDIS_VERSION_SHORT}.service" << EOF
[Unit]
Description=RustyPanel Redis ${REDIS_BRANCH} Data Store
After=network.target

[Service]
Type=notify
User=rustypanel
Group=rustypanel
ExecStart=${INSTALL_PREFIX}/bin/redis-server ${INSTALL_PREFIX}/etc/redis.conf
ExecStop=${INSTALL_PREFIX}/bin/redis-cli shutdown
Restart=on-failure
RestartSec=5
RuntimeDirectory=rustypanel
RuntimeDirectoryMode=0755
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
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
Section: database
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${installed_size}
Depends: libc6, libssl3, libsystemd0
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: Redis ${REDIS_BRANCH} for RustyPanel
 Pre-compiled Redis ${REDIS_VERSION} in-memory data store.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - TLS support
  - Unix socket support
  - Systemd integration
  - Persistence (RDB + AOF)
EOF

    # postinst
    cat > "${debian_dir}/postinst" << EOF
#!/bin/bash
set -e

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create directories
mkdir -p /rp/logs/redis
mkdir -p /rp/data/redis/${REDIS_BRANCH}
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/redis
chown -R rustypanel:rustypanel /rp/data/redis
chown rustypanel:rustypanel /run/rustypanel

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-redis${REDIS_VERSION_SHORT}.service || true

echo "RustyPanel Redis ${REDIS_BRANCH} installed successfully!"
echo "Start with: systemctl start rustypanel-redis${REDIS_VERSION_SHORT}"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << EOF
#!/bin/bash
set -e

systemctl stop rustypanel-redis${REDIS_VERSION_SHORT}.service || true
systemctl disable rustypanel-redis${REDIS_VERSION_SHORT}.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << EOF
#!/bin/bash
set -e

if [ "\$1" = "purge" ]; then
    rm -rf /rp/data/redis/${REDIS_BRANCH}
fi

systemctl daemon-reload
EOF
    chmod 755 "${debian_dir}/postrm"

    # conffiles
    cat > "${debian_dir}/conffiles" << EOF
${INSTALL_PREFIX}/etc/redis.conf
EOF
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
    log_info "RustyPanel Redis Package Builder"
    log_info "==================================="
    log_info "Redis Version:  ${REDIS_VERSION} (${REDIS_BRANCH})"
    log_info "Distribution:   ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:   ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_redis
    build_redis
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
