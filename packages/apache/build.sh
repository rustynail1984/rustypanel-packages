#!/bin/bash
set -euo pipefail

# RustyPanel Apache Builder

APACHE_BRANCH="${VERSION:-2.4}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/apache-build"
INSTALL_PREFIX="/rp/apps/apache"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Apache version mapping
declare -A APACHE_VERSIONS=(
    ["2.4"]="2.4.63"
)

APACHE_VERSION="${APACHE_VERSIONS[$APACHE_BRANCH]:-}"
if [[ -z "$APACHE_VERSION" ]]; then
    log_error "Unknown Apache branch: $APACHE_BRANCH"
    exit 1
fi

APR_VERSION="1.7.5"
APR_UTIL_VERSION="1.6.3"

PACKAGE_NAME="rustypanel-apache"
PACKAGE_VERSION="${APACHE_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        libpcre2-dev \
        libssl-dev \
        libxml2-dev \
        libexpat1-dev \
        libcurl4-openssl-dev \
        liblua5.4-dev \
        libnghttp2-dev \
        libbrotli-dev \
        libjansson-dev \
        zlib1g-dev \
        dpkg-dev \
        fakeroot
}

download_sources() {
    log_info "Downloading sources..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # APR
    log_info "Downloading APR ${APR_VERSION}..."
    wget -q --tries=3 "https://archive.apache.org/dist/apr/apr-${APR_VERSION}.tar.gz" -O apr.tar.gz \
        || wget -q --tries=3 "https://dlcdn.apache.org/apr/apr-${APR_VERSION}.tar.gz" -O apr.tar.gz
    tar -xzf apr.tar.gz

    # APR-util
    log_info "Downloading APR-util ${APR_UTIL_VERSION}..."
    wget -q --tries=3 "https://archive.apache.org/dist/apr/apr-util-${APR_UTIL_VERSION}.tar.gz" -O apr-util.tar.gz \
        || wget -q --tries=3 "https://dlcdn.apache.org/apr/apr-util-${APR_UTIL_VERSION}.tar.gz" -O apr-util.tar.gz
    tar -xzf apr-util.tar.gz

    # Apache HTTPD
    log_info "Downloading Apache ${APACHE_VERSION}..."
    wget -q --tries=3 "https://archive.apache.org/dist/httpd/httpd-${APACHE_VERSION}.tar.gz" -O httpd.tar.gz \
        || wget -q --tries=3 "https://dlcdn.apache.org/httpd/httpd-${APACHE_VERSION}.tar.gz" -O httpd.tar.gz
    tar -xzf httpd.tar.gz

    # Move APR into srclib
    mv "apr-${APR_VERSION}" "httpd-${APACHE_VERSION}/srclib/apr"
    mv "apr-util-${APR_UTIL_VERSION}" "httpd-${APACHE_VERSION}/srclib/apr-util"

    cd "httpd-${APACHE_VERSION}"
}

configure_apache() {
    log_info "Configuring Apache..."

    ./configure \
        --prefix="${INSTALL_PREFIX}" \
        --sysconfdir="${INSTALL_PREFIX}/etc" \
        --with-included-apr \
        --enable-so \
        --enable-ssl \
        --enable-http2 \
        --enable-proxy \
        --enable-proxy-fcgi \
        --enable-proxy-http \
        --enable-proxy-wstunnel \
        --enable-rewrite \
        --enable-headers \
        --enable-expires \
        --enable-deflate \
        --enable-brotli \
        --enable-mods-shared=all \
        --enable-mpms-shared=all \
        --with-mpm=event \
        --with-ssl \
        --with-nghttp2 \
        --with-brotli
}

build_apache() {
    log_info "Building Apache (this may take a while)..."

    make -j"$(nproc)"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install Apache to package directory
    make DESTDIR="$pkg_dir" install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/sites-available"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/sites-enabled"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/conf.d"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-apache.service" << EOF
[Unit]
Description=RustyPanel Apache HTTP Server
After=network.target

[Service]
Type=forking
PIDFile=/run/rustypanel/apache.pid
ExecStart=${INSTALL_PREFIX}/bin/apachectl start
ExecStop=${INSTALL_PREFIX}/bin/apachectl graceful-stop
ExecReload=${INSTALL_PREFIX}/bin/apachectl graceful
PrivateTmp=true
RuntimeDirectory=rustypanel
RuntimeDirectoryMode=0755

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
        <p>Apache is running successfully.</p>
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
Depends: libc6, libpcre2-8-0, libssl3 | libssl1.1, libxml2, libnghttp2-14, libbrotli1, zlib1g
Conflicts: apache2, apache2-bin
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: Apache ${APACHE_VERSION} for RustyPanel
 Pre-compiled Apache ${APACHE_VERSION} HTTP server.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - HTTP/2 support
  - Brotli compression
  - Event MPM
  - mod_proxy with FastCGI support
  - mod_rewrite, mod_headers, mod_expires
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
mkdir -p /rp/logs/apache
mkdir -p /rp/wwwroot
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/apache
chown -R rustypanel:rustypanel /rp/wwwroot
chown rustypanel:rustypanel /run/rustypanel

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-apache.service || true

echo "RustyPanel Apache installed successfully!"
echo "Start with: systemctl start rustypanel-apache"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

systemctl stop rustypanel-apache.service || true
systemctl disable rustypanel-apache.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    rm -rf /rp/apps/apache
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
    log_info "RustyPanel Apache Package Builder"
    log_info "==================================="
    log_info "Apache Version: ${APACHE_VERSION} (${APACHE_BRANCH})"
    log_info "Distribution:   ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:   ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_sources
    configure_apache
    build_apache
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
