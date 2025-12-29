#!/bin/bash
set -euo pipefail

# RustyPanel HAProxy Builder

HAPROXY_BRANCH="${VERSION:-3.0}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/haproxy-build"
INSTALL_PREFIX="/rp/apps/haproxy"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# HAProxy version mapping
declare -A HAPROXY_VERSIONS=(
    ["3.0"]="3.0.7"
    ["2.9"]="2.9.12"
)

HAPROXY_VERSION="${HAPROXY_VERSIONS[$HAPROXY_BRANCH]:-}"
if [[ -z "$HAPROXY_VERSION" ]]; then
    log_error "Unknown HAProxy branch: $HAPROXY_BRANCH"
    exit 1
fi

PACKAGE_NAME="rustypanel-haproxy"
PACKAGE_VERSION="${HAPROXY_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        libssl-dev \
        libpcre2-dev \
        libsystemd-dev \
        liblua5.4-dev \
        zlib1g-dev \
        dpkg-dev \
        fakeroot
}

download_haproxy() {
    log_info "Downloading HAProxy ${HAPROXY_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    local major_minor="${HAPROXY_VERSION%.*}"
    wget -q "https://www.haproxy.org/download/${major_minor}/src/haproxy-${HAPROXY_VERSION}.tar.gz" -O haproxy.tar.gz
    tar -xzf haproxy.tar.gz
    cd "haproxy-${HAPROXY_VERSION}"
}

build_haproxy() {
    log_info "Building HAProxy..."

    make -j"$(nproc)" \
        TARGET=linux-glibc \
        USE_OPENSSL=1 \
        USE_PCRE2=1 \
        USE_PCRE2_JIT=1 \
        USE_SYSTEMD=1 \
        USE_LUA=1 \
        USE_ZLIB=1 \
        USE_PROMEX=1 \
        SSL_INC=/usr/include \
        SSL_LIB=/usr/lib \
        PREFIX="${INSTALL_PREFIX}"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/sbin"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/errors"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # Install HAProxy binary
    make install DESTDIR="$pkg_dir" PREFIX="${INSTALL_PREFIX}"

    # Copy error files
    cp -r examples/errorfiles/* "${pkg_dir}${INSTALL_PREFIX}/etc/errors/" 2>/dev/null || true

    # Default config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/haproxy.cfg" << 'EOF'
# RustyPanel HAProxy Configuration

global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /rp/data/haproxy
    stats socket /run/rustypanel/haproxy.sock mode 660 level admin
    stats timeout 30s
    user rustypanel
    group rustypanel
    daemon

    # SSL settings
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    option  forwardfor
    option  http-server-close
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /rp/apps/haproxy/etc/errors/400.http
    errorfile 403 /rp/apps/haproxy/etc/errors/403.http
    errorfile 408 /rp/apps/haproxy/etc/errors/408.http
    errorfile 500 /rp/apps/haproxy/etc/errors/500.http
    errorfile 502 /rp/apps/haproxy/etc/errors/502.http
    errorfile 503 /rp/apps/haproxy/etc/errors/503.http
    errorfile 504 /rp/apps/haproxy/etc/errors/504.http

# Stats page
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST

# HTTP Frontend
frontend http_front
    bind *:80
    mode http
    default_backend http_back

# Default backend
backend http_back
    mode http
    balance roundrobin
    option httpchk GET /
    server web1 127.0.0.1:8080 check

# Prometheus metrics (optional)
frontend prometheus
    bind *:8405
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    no log
EOF

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-haproxy.service" << EOF
[Unit]
Description=RustyPanel HAProxy Load Balancer
After=network.target

[Service]
Type=notify
EnvironmentFile=-/rp/apps/haproxy/etc/haproxy.env
ExecStartPre=${INSTALL_PREFIX}/sbin/haproxy -f ${INSTALL_PREFIX}/etc/haproxy.cfg -c -q
ExecStart=${INSTALL_PREFIX}/sbin/haproxy -Ws -f ${INSTALL_PREFIX}/etc/haproxy.cfg -p /run/rustypanel/haproxy.pid
ExecReload=${INSTALL_PREFIX}/sbin/haproxy -f ${INSTALL_PREFIX}/etc/haproxy.cfg -c -q
ExecReload=/bin/kill -USR2 \$MAINPID
KillMode=mixed
Restart=on-failure
RestartSec=5
RuntimeDirectory=rustypanel
RuntimeDirectoryMode=0755

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
Section: net
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${installed_size}
Depends: libc6, libssl3 | libssl1.1, libpcre2-8-0, libsystemd0, liblua5.4-0 | liblua5.3-0, zlib1g
Conflicts: haproxy
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: HAProxy ${HAPROXY_VERSION} for RustyPanel
 Pre-compiled HAProxy ${HAPROXY_VERSION} load balancer.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - HTTP/HTTPS load balancing
  - TCP/UDP proxy
  - SSL/TLS termination
  - Health checks
  - Stats dashboard
  - Prometheus metrics exporter
  - Lua scripting support
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
mkdir -p /rp/logs/haproxy
mkdir -p /rp/data/haproxy
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/haproxy
chown -R rustypanel:rustypanel /rp/data/haproxy
chown rustypanel:rustypanel /run/rustypanel

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-haproxy.service || true

echo "RustyPanel HAProxy installed successfully!"
echo "Start with: systemctl start rustypanel-haproxy"
echo ""
echo "Stats dashboard: http://localhost:8404/stats"
echo "Prometheus metrics: http://localhost:8405/metrics"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

systemctl stop rustypanel-haproxy.service || true
systemctl disable rustypanel-haproxy.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    rm -rf /rp/apps/haproxy
    rm -rf /rp/data/haproxy
fi

systemctl daemon-reload
EOF
    chmod 755 "${debian_dir}/postrm"

    # conffiles
    cat > "${debian_dir}/conffiles" << EOF
${INSTALL_PREFIX}/etc/haproxy.cfg
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
    log_info "RustyPanel HAProxy Package Builder"
    log_info "==================================="
    log_info "HAProxy Version: ${HAPROXY_VERSION} (${HAPROXY_BRANCH})"
    log_info "Distribution:    ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:    ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_haproxy
    build_haproxy
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
