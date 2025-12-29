#!/bin/bash
set -euo pipefail

# RustyPanel Varnish Cache Builder

VARNISH_BRANCH="${VERSION:-7.6}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/varnish-build"
INSTALL_PREFIX="/rp/apps/varnish"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Varnish version mapping
declare -A VARNISH_VERSIONS=(
    ["7.6"]="7.6.1"
    ["7.5"]="7.5.0"
)

VARNISH_VERSION="${VARNISH_VERSIONS[$VARNISH_BRANCH]:-}"
if [[ -z "$VARNISH_VERSION" ]]; then
    log_error "Unknown Varnish branch: $VARNISH_BRANCH"
    exit 1
fi

PACKAGE_NAME="rustypanel-varnish"
PACKAGE_VERSION="${VARNISH_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        automake \
        autotools-dev \
        libtool \
        pkg-config \
        python3 \
        python3-sphinx \
        python3-docutils \
        libpcre2-dev \
        libncurses-dev \
        libedit-dev \
        libunwind-dev \
        dpkg-dev \
        fakeroot
}

download_sources() {
    log_info "Downloading Varnish ${VARNISH_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    wget -q "https://varnish-cache.org/_downloads/varnish-${VARNISH_VERSION}.tgz" -O varnish.tgz
    tar -xzf varnish.tgz
    cd "varnish-${VARNISH_VERSION}"
}

configure_varnish() {
    log_info "Configuring Varnish..."

    ./configure \
        --prefix="${INSTALL_PREFIX}" \
        --sysconfdir="${INSTALL_PREFIX}/etc" \
        --localstatedir=/rp/data/varnish \
        --with-unwind
}

build_varnish() {
    log_info "Building Varnish (this may take a while)..."

    make -j"$(nproc)"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install Varnish to package directory
    make DESTDIR="$pkg_dir" install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # Default VCL
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/default.vcl" << 'EOF'
# RustyPanel Varnish Default VCL

vcl 4.1;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .connect_timeout = 5s;
    .first_byte_timeout = 60s;
    .between_bytes_timeout = 10s;
}

sub vcl_recv {
    # Remove cookies for static files
    if (req.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot)$") {
        unset req.http.Cookie;
        return (hash);
    }

    # Pass requests with Authorization header
    if (req.http.Authorization) {
        return (pass);
    }
}

sub vcl_backend_response {
    # Cache static files for 1 day
    if (bereq.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot)$") {
        set beresp.ttl = 1d;
        unset beresp.http.Set-Cookie;
    }

    # Enable grace mode
    set beresp.grace = 1h;
}

sub vcl_deliver {
    # Add cache hit/miss header
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
EOF

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-varnish.service" << EOF
[Unit]
Description=RustyPanel Varnish Cache
After=network.target

[Service]
Type=forking
PIDFile=/run/rustypanel/varnish.pid
ExecStart=${INSTALL_PREFIX}/sbin/varnishd \\
    -a :6081 \\
    -a :6082,PROXY \\
    -f ${INSTALL_PREFIX}/etc/default.vcl \\
    -s malloc,256M \\
    -P /run/rustypanel/varnish.pid
ExecReload=/bin/kill -HUP \$MAINPID
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
Section: web
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${installed_size}
Depends: libc6, libpcre2-8-0 | libpcre3, libncurses6 | libncurses5, libedit2, libunwind8 | libunwind-14
Conflicts: varnish
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: Varnish Cache ${VARNISH_VERSION} for RustyPanel
 Pre-compiled Varnish Cache ${VARNISH_VERSION} HTTP accelerator.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - High-performance HTTP reverse proxy
  - VCL configuration language
  - Grace mode for stale content serving
  - ESI support
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
mkdir -p /rp/logs/varnish
mkdir -p /rp/data/varnish
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/varnish
chown -R rustypanel:rustypanel /rp/data/varnish
chown rustypanel:rustypanel /run/rustypanel

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-varnish.service || true

echo "RustyPanel Varnish installed successfully!"
echo "Start with: systemctl start rustypanel-varnish"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

systemctl stop rustypanel-varnish.service || true
systemctl disable rustypanel-varnish.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    rm -rf /rp/apps/varnish
    rm -rf /rp/data/varnish
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
    log_info "RustyPanel Varnish Package Builder"
    log_info "==================================="
    log_info "Varnish Version: ${VARNISH_VERSION} (${VARNISH_BRANCH})"
    log_info "Distribution:    ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:    ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_sources
    configure_varnish
    build_varnish
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
