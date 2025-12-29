#!/bin/bash
set -euo pipefail

# RustyPanel MariaDB Builder
# This script runs inside a Docker container

MARIADB_MAJOR_MINOR="${VERSION:-11.4}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/mariadb-build"
INSTALL_PREFIX="/rp/apps/mariadb/${MARIADB_MAJOR_MINOR}"
DATA_DIR="/rp/data/mariadb/${MARIADB_MAJOR_MINOR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# MariaDB version mapping
declare -A MARIADB_VERSIONS=(
    ["11.4"]="11.4.4"
    ["11.2"]="11.2.6"
    ["10.11"]="10.11.10"
    ["10.6"]="10.6.20"
)

MARIADB_FULL_VERSION="${MARIADB_VERSIONS[$MARIADB_MAJOR_MINOR]:-}"
if [[ -z "$MARIADB_FULL_VERSION" ]]; then
    log_error "Unknown MariaDB version: $MARIADB_MAJOR_MINOR"
    exit 1
fi

MARIADB_VERSION_SHORT="${MARIADB_MAJOR_MINOR//./}"
PACKAGE_NAME="rustypanel-mariadb${MARIADB_VERSION_SHORT}"
PACKAGE_VERSION="${MARIADB_FULL_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        pkg-config \
        ca-certificates \
        curl \
        wget \
        gnutls-dev \
        libncurses5-dev \
        libssl-dev \
        libcurl4-openssl-dev \
        libevent-dev \
        libxml2-dev \
        liblz4-dev \
        liblzma-dev \
        libzstd-dev \
        zlib1g-dev \
        libreadline-dev \
        libpam0g-dev \
        libcrack2-dev \
        libjemalloc-dev \
        libaio-dev \
        libsystemd-dev \
        libboost-dev \
        bison \
        dpkg-dev \
        fakeroot
}

download_mariadb() {
    log_info "Downloading MariaDB ${MARIADB_FULL_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    local url="https://downloads.mariadb.org/rest-api/mariadb/${MARIADB_FULL_VERSION}/mariadb-${MARIADB_FULL_VERSION}.tar.gz"
    # Alternative mirror
    local mirror_url="https://archive.mariadb.org/mariadb-${MARIADB_FULL_VERSION}/source/mariadb-${MARIADB_FULL_VERSION}.tar.gz"

    if ! wget -q "$url" -O mariadb.tar.gz; then
        wget -q "$mirror_url" -O mariadb.tar.gz
    fi

    tar -xzf mariadb.tar.gz
    cd "mariadb-${MARIADB_FULL_VERSION}"
}

configure_mariadb() {
    log_info "Configuring MariaDB..."

    mkdir -p build
    cd build

    cmake .. \
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
        -DMYSQL_DATADIR="${DATA_DIR}" \
        -DSYSCONFDIR="${INSTALL_PREFIX}/etc" \
        -DMYSQL_UNIX_ADDR="/run/rustypanel/mariadb-${MARIADB_MAJOR_MINOR}.sock" \
        -DWITH_INNOBASE_STORAGE_ENGINE=1 \
        -DWITH_PARTITION_STORAGE_ENGINE=1 \
        -DWITH_FEDERATED_STORAGE_ENGINE=1 \
        -DWITH_BLACKHOLE_STORAGE_ENGINE=1 \
        -DWITH_MYISAM_STORAGE_ENGINE=1 \
        -DWITH_ARCHIVE_STORAGE_ENGINE=1 \
        -DWITH_READLINE=1 \
        -DWITH_SSL=system \
        -DWITH_ZLIB=system \
        -DWITH_LIBWRAP=0 \
        -DENABLED_LOCAL_INFILE=1 \
        -DDEFAULT_CHARSET=utf8mb4 \
        -DDEFAULT_COLLATION=utf8mb4_general_ci \
        -DWITH_SYSTEMD=yes \
        -DWITH_JEMALLOC=yes
}

build_mariadb() {
    log_info "Building MariaDB (this may take a while)..."

    make -j"$(nproc)"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install MariaDB to package directory
    make DESTDIR="$pkg_dir" install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # MariaDB config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/my.cnf" << EOF
# RustyPanel MariaDB ${MARIADB_MAJOR_MINOR} Configuration

[client]
port = 3306
socket = /run/rustypanel/mariadb-${MARIADB_MAJOR_MINOR}.sock
default-character-set = utf8mb4

[mysqld]
# Basic Settings
user = rustypanel
port = 3306
basedir = ${INSTALL_PREFIX}
datadir = ${DATA_DIR}
socket = /run/rustypanel/mariadb-${MARIADB_MAJOR_MINOR}.sock
pid-file = /run/rustypanel/mariadb-${MARIADB_MAJOR_MINOR}.pid

# Character Set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
init-connect = 'SET NAMES utf8mb4'

# InnoDB Settings
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT

# Connections
max_connections = 151
max_allowed_packet = 64M
wait_timeout = 28800
interactive_timeout = 28800

# Query Cache (disabled by default in newer versions)
query_cache_type = 0
query_cache_size = 0

# Logging
log_error = /rp/logs/mariadb/mariadb-${MARIADB_MAJOR_MINOR}-error.log
slow_query_log = 1
slow_query_log_file = /rp/logs/mariadb/mariadb-${MARIADB_MAJOR_MINOR}-slow.log
long_query_time = 2

# Security
local_infile = 0
symbolic-links = 0

[mysqldump]
quick
quote-names
max_allowed_packet = 64M

[mysql]
no-auto-rehash
default-character-set = utf8mb4
EOF

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-mariadb${MARIADB_VERSION_SHORT}.service" << EOF
[Unit]
Description=RustyPanel MariaDB ${MARIADB_MAJOR_MINOR} Database Server
After=network.target

[Service]
Type=notify
User=rustypanel
Group=rustypanel
ExecStartPre=${INSTALL_PREFIX}/scripts/mysql_install_db --user=rustypanel --datadir=${DATA_DIR} --skip-test-db
ExecStart=${INSTALL_PREFIX}/bin/mariadbd --defaults-file=${INSTALL_PREFIX}/etc/my.cnf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
RuntimeDirectory=rustypanel
RuntimeDirectoryMode=0755

LimitNOFILE=65535
PrivateTmp=true

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
Depends: libc6, libssl3 | libssl1.1, libncurses6 | libncurses5, zlib1g, liblz4-1, libzstd1, libjemalloc2, libaio1t64 | libaio1
Conflicts: mysql-server, mariadb-server
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: MariaDB ${MARIADB_MAJOR_MINOR} for RustyPanel
 Pre-compiled MariaDB ${MARIADB_FULL_VERSION} database server.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features: InnoDB, MyISAM, Archive, Blackhole, Federated storage engines.
 Optimized configuration for web hosting environments.
EOF

    # postinst
    cat > "${debian_dir}/postinst" << 'EOF'
#!/bin/bash
set -e

VERSION_SHORT="${VERSION_SHORT}"
VERSION="${VERSION}"
INSTALL_PREFIX="${INSTALL_PREFIX}"
DATA_DIR="${DATA_DIR}"

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create directories
mkdir -p /rp/logs/mariadb
mkdir -p "${DATA_DIR}"
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/mariadb
chown -R rustypanel:rustypanel "${DATA_DIR}"
chown rustypanel:rustypanel /run/rustypanel

# Initialize database if not exists
if [ ! -d "${DATA_DIR}/mysql" ]; then
    echo "Initializing MariaDB database..."
    "${INSTALL_PREFIX}/scripts/mysql_install_db" \
        --user=rustypanel \
        --datadir="${DATA_DIR}" \
        --skip-test-db
fi

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-mariadb${VERSION_SHORT}.service || true

echo "RustyPanel MariaDB ${VERSION} installed successfully!"
echo "Start with: systemctl start rustypanel-mariadb${VERSION_SHORT}"
echo ""
echo "IMPORTANT: Run mysql_secure_installation after first start!"
EOF
    sed -i "s/\${VERSION_SHORT}/${MARIADB_VERSION_SHORT}/g" "${debian_dir}/postinst"
    sed -i "s/\${VERSION}/${MARIADB_MAJOR_MINOR}/g" "${debian_dir}/postinst"
    sed -i "s|\${INSTALL_PREFIX}|${INSTALL_PREFIX}|g" "${debian_dir}/postinst"
    sed -i "s|\${DATA_DIR}|${DATA_DIR}|g" "${debian_dir}/postinst"
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

# Stop service before removal
systemctl stop rustypanel-mariadb${VERSION_SHORT}.service || true
systemctl disable rustypanel-mariadb${VERSION_SHORT}.service || true
EOF
    sed -i "s/\${VERSION_SHORT}/${MARIADB_VERSION_SHORT}/g" "${debian_dir}/prerm"
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    echo "Note: Data directory ${DATA_DIR} was NOT removed."
    echo "Remove manually if no longer needed."
fi

systemctl daemon-reload
EOF
    sed -i "s|\${DATA_DIR}|${DATA_DIR}|g" "${debian_dir}/postrm"
    chmod 755 "${debian_dir}/postrm"

    # conffiles
    cat > "${debian_dir}/conffiles" << EOF
${INSTALL_PREFIX}/etc/my.cnf
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
    log_info "RustyPanel MariaDB Package Builder"
    log_info "==================================="
    log_info "MariaDB Version: ${MARIADB_FULL_VERSION} (${MARIADB_MAJOR_MINOR})"
    log_info "Distribution:    ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:    ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_mariadb
    configure_mariadb
    build_mariadb
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
