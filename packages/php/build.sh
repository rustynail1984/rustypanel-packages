#!/bin/bash
set -euo pipefail

# RustyPanel PHP Builder
# This script runs inside a Docker container

PHP_MAJOR_MINOR="${VERSION:-8.3}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/php-build"
INSTALL_PREFIX="/rp/apps/php/${PHP_MAJOR_MINOR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# PHP version mapping
declare -A PHP_VERSIONS=(
    ["8.5"]="8.5.1"
    ["8.4"]="8.4.16"
    ["8.3"]="8.3.29"
    ["8.2"]="8.2.30"
    ["8.1"]="8.1.34"
    ["8.0"]="8.0.30"
    ["7.4"]="7.4.33"
)

PHP_FULL_VERSION="${PHP_VERSIONS[$PHP_MAJOR_MINOR]:-}"
if [[ -z "$PHP_FULL_VERSION" ]]; then
    log_error "Unknown PHP version: $PHP_MAJOR_MINOR"
    exit 1
fi

PHP_VERSION_SHORT="${PHP_MAJOR_MINOR//./}"
PACKAGE_NAME="rustypanel-php${PHP_VERSION_SHORT}"
PACKAGE_VERSION="${PHP_FULL_VERSION}-1"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        bison \
        re2c \
        pkg-config \
        ca-certificates \
        curl \
        wget \
        xz-utils \
        dpkg-dev \
        fakeroot \
        \
        libxml2-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        libjpeg-dev \
        libpng-dev \
        libwebp-dev \
        libfreetype6-dev \
        libxpm-dev \
        libgd-dev \
        libonig-dev \
        libreadline-dev \
        libsqlite3-dev \
        libpq-dev \
        libzip-dev \
        libsodium-dev \
        libxslt1-dev \
        libbz2-dev \
        libgmp-dev \
        libicu-dev \
        libkrb5-dev \
        libldap2-dev \
        libsasl2-dev \
        libtidy-dev \
        libargon2-dev
}

download_php() {
    log_info "Downloading PHP ${PHP_FULL_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    local url="https://www.php.net/distributions/php-${PHP_FULL_VERSION}.tar.xz"
    wget -q "$url" -O php.tar.xz
    tar -xf php.tar.xz
    cd "php-${PHP_FULL_VERSION}"
}

configure_php() {
    log_info "Configuring PHP..."

    ./configure \
        --prefix="${INSTALL_PREFIX}" \
        --with-config-file-path="${INSTALL_PREFIX}/etc" \
        --with-config-file-scan-dir="${INSTALL_PREFIX}/etc/conf.d" \
        --enable-fpm \
        --with-fpm-user=rustypanel \
        --with-fpm-group=rustypanel \
        --disable-cgi \
        --enable-mysqlnd \
        --with-mysqli=mysqlnd \
        --with-pdo-mysql=mysqlnd \
        --with-pgsql \
        --with-pdo-pgsql \
        --with-sqlite3 \
        --with-pdo-sqlite \
        --with-openssl \
        --with-zlib \
        --with-bz2 \
        --with-curl \
        --enable-gd \
        --with-jpeg \
        --with-webp \
        --with-freetype \
        --with-xpm \
        --with-gettext \
        --with-gmp \
        --with-iconv \
        --enable-intl \
        --enable-mbstring \
        --with-readline \
        --with-sodium \
        --with-xsl \
        --with-zip \
        --enable-bcmath \
        --enable-calendar \
        --enable-exif \
        --enable-ftp \
        --enable-opcache \
        --enable-pcntl \
        --enable-shmop \
        --enable-soap \
        --enable-sockets \
        --enable-sysvmsg \
        --enable-sysvsem \
        --enable-sysvshm \
        --with-password-argon2
}

build_php() {
    log_info "Building PHP (this may take a while)..."

    make -j"$(nproc)"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install PHP to package directory
    make INSTALL_ROOT="$pkg_dir" install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/conf.d"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/fpm.d"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # Copy default configs
    cp php.ini-production "${pkg_dir}${INSTALL_PREFIX}/etc/php.ini"

    # PHP-FPM config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/php-fpm.conf" << 'EOF'
[global]
pid = /run/rustypanel/php-fpm-${VERSION}.pid
error_log = /rp/logs/php/php${VERSION}-fpm.log
log_level = notice
daemonize = no

include=/rp/apps/php/${VERSION}/etc/fpm.d/*.conf
EOF
    sed -i "s/\${VERSION}/${PHP_MAJOR_MINOR}/g" "${pkg_dir}${INSTALL_PREFIX}/etc/php-fpm.conf"

    # Default pool
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/fpm.d/www.conf" << 'EOF'
[www]
user = rustypanel
group = rustypanel

listen = /run/rustypanel/php-fpm-${VERSION}.sock
listen.owner = rustypanel
listen.group = rustypanel
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35

slowlog = /rp/logs/php/php${VERSION}-slow.log
request_slowlog_timeout = 30s
EOF
    sed -i "s/\${VERSION}/${PHP_MAJOR_MINOR}/g" "${pkg_dir}${INSTALL_PREFIX}/etc/fpm.d/www.conf"

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-php${PHP_VERSION_SHORT}-fpm.service" << EOF
[Unit]
Description=RustyPanel PHP ${PHP_MAJOR_MINOR} FastCGI Process Manager
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_PREFIX}/sbin/php-fpm --nodaemonize --fpm-config ${INSTALL_PREFIX}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
ExecStop=/bin/kill -SIGTERM \$MAINPID
PrivateTmp=true
RuntimeDirectory=rustypanel
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    # OPcache config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/conf.d/10-opcache.ini" << 'EOF'
[opcache]
zend_extension=opcache
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.save_comments=1
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
Depends: libc6, libcurl4, libgd3, libicu72 | libicu70, libjpeg62-turbo | libjpeg-turbo8, libonig5, libpng16-16, libpq5, libreadline8, libsodium23, libsqlite3-0, libssl3, libwebp7 | libwebp6, libxml2, libxslt1.1, libzip4, zlib1g, libargon2-1, libfreetype6
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: PHP ${PHP_MAJOR_MINOR} for RustyPanel
 Pre-compiled PHP ${PHP_FULL_VERSION} with FPM and common extensions.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Included extensions: bcmath, calendar, ctype, curl, dom, exif, fileinfo,
 filter, ftp, gd, gettext, gmp, iconv, intl, json, mbstring, mysqli,
 mysqlnd, opcache, openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite,
 pgsql, phar, posix, readline, session, shmop, simplexml, soap, sockets,
 sodium, sqlite3, sysvmsg, sysvsem, sysvshm, tokenizer, xml, xmlreader,
 xmlwriter, xsl, zip, zlib.
EOF

    # postinst
    cat > "${debian_dir}/postinst" << 'EOF'
#!/bin/bash
set -e

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create log directory
mkdir -p /rp/logs/php
chown rustypanel:rustypanel /rp/logs/php

# Create runtime directory
mkdir -p /run/rustypanel
chown rustypanel:rustypanel /run/rustypanel

# Enable and start service
systemctl daemon-reload
systemctl enable rustypanel-php${VERSION_SHORT}-fpm.service || true

echo "RustyPanel PHP ${VERSION} installed successfully!"
echo "Start with: systemctl start rustypanel-php${VERSION_SHORT}-fpm"
EOF
    sed -i "s/\${VERSION_SHORT}/${PHP_VERSION_SHORT}/g" "${debian_dir}/postinst"
    sed -i "s/\${VERSION}/${PHP_MAJOR_MINOR}/g" "${debian_dir}/postinst"
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

# Stop service before removal
systemctl stop rustypanel-php${VERSION_SHORT}-fpm.service || true
systemctl disable rustypanel-php${VERSION_SHORT}-fpm.service || true
EOF
    sed -i "s/\${VERSION_SHORT}/${PHP_VERSION_SHORT}/g" "${debian_dir}/prerm"
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    rm -rf /rp/apps/php/${VERSION}
fi

systemctl daemon-reload
EOF
    sed -i "s/\${VERSION}/${PHP_MAJOR_MINOR}/g" "${debian_dir}/postrm"
    chmod 755 "${debian_dir}/postrm"

    # conffiles
    cat > "${debian_dir}/conffiles" << EOF
${INSTALL_PREFIX}/etc/php.ini
${INSTALL_PREFIX}/etc/php-fpm.conf
${INSTALL_PREFIX}/etc/fpm.d/www.conf
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
    log_info "RustyPanel PHP Package Builder"
    log_info "==================================="
    log_info "PHP Version:  ${PHP_FULL_VERSION} (${PHP_MAJOR_MINOR})"
    log_info "Distribution: ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture: ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_php
    configure_php
    build_php
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
