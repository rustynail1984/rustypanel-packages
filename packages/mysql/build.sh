#!/bin/bash
set -euo pipefail

# RustyPanel MySQL Builder

MYSQL_BRANCH="${VERSION:-8.4}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/mysql-build"
INSTALL_PREFIX="/rp/apps/mysql/${MYSQL_BRANCH}"
DATA_DIR="/rp/data/mysql/${MYSQL_BRANCH}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# MySQL version mapping
declare -A MYSQL_VERSIONS=(
    ["8.4"]="8.4.4"
    ["8.0"]="8.0.41"
    ["5.7"]="5.7.44"
)

MYSQL_VERSION="${MYSQL_VERSIONS[$MYSQL_BRANCH]:-}"
if [[ -z "$MYSQL_VERSION" ]]; then
    log_error "Unknown MySQL branch: $MYSQL_BRANCH"
    exit 1
fi

MYSQL_VERSION_SHORT="${MYSQL_BRANCH//./}"
PACKAGE_NAME="rustypanel-mysql${MYSQL_VERSION_SHORT}"
PACKAGE_VERSION="${MYSQL_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

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
        bison \
        libssl-dev \
        libncurses5-dev \
        libtirpc-dev \
        libaio-dev \
        libnuma-dev \
        libldap2-dev \
        libsasl2-dev \
        libsystemd-dev \
        libcurl4-openssl-dev \
        libevent-dev \
        liblz4-dev \
        libzstd-dev \
        zlib1g-dev \
        dpkg-dev \
        fakeroot
}

download_mysql() {
    log_info "Downloading MySQL ${MYSQL_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    local url="https://dev.mysql.com/get/Downloads/MySQL-${MYSQL_BRANCH}/mysql-${MYSQL_VERSION}.tar.gz"
    wget -q "$url" -O mysql.tar.gz || {
        # Try boost bundled version
        url="https://dev.mysql.com/get/Downloads/MySQL-${MYSQL_BRANCH}/mysql-boost-${MYSQL_VERSION}.tar.gz"
        wget -q "$url" -O mysql.tar.gz
    }
    tar -xzf mysql.tar.gz
    cd "mysql-${MYSQL_VERSION}"
}

configure_mysql() {
    log_info "Configuring MySQL..."

    mkdir -p build
    cd build

    local cmake_opts=(
        -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
        -DMYSQL_DATADIR="${DATA_DIR}"
        -DSYSCONFDIR="${INSTALL_PREFIX}/etc"
        -DMYSQL_UNIX_ADDR="/run/rustypanel/mysql-${MYSQL_BRANCH}.sock"
        -DWITH_SSL=system
        -DWITH_ZLIB=system
        -DWITH_LZ4=system
        -DWITH_ZSTD=system
        -DWITH_INNODB_MEMCACHED=ON
        -DDOWNLOAD_BOOST=1
        -DWITH_BOOST="../boost"
        -DENABLED_LOCAL_INFILE=ON
        -DDEFAULT_CHARSET=utf8mb4
        -DDEFAULT_COLLATION=utf8mb4_general_ci
        -DWITH_SYSTEMD=OFF
    )

    # MySQL 5.7 specific options (EOL - needs compatibility fixes)
    if [[ "$MYSQL_BRANCH" == "5.7" ]]; then
        # MySQL 5.7 needs relaxed compiler flags for modern GCC and bundled SSL
        local compat_cflags="-O2 -Wno-error -Wno-deprecated-declarations"
        local compat_cxxflags="-O2 -Wno-error -Wno-deprecated-declarations -Wno-error=deprecated-copy -Wno-error=redundant-move -std=c++14"
        cmake_opts+=(
            -DWITH_EMBEDDED_SERVER=OFF
            -DWITH_SSL=bundled
            -DWITH_ZSTD=bundled
            -DFORCE_INSOURCE_BUILD=1
            -DCMAKE_C_FLAGS="${compat_cflags}"
            -DCMAKE_CXX_FLAGS="${compat_cxxflags}"
        )
    fi

    cmake .. "${cmake_opts[@]}"
}

build_mysql() {
    log_info "Building MySQL (this may take a while)..."

    # Limit parallelism - MySQL needs ~2-4GB RAM per compile thread
    # Use half of available cores, max 16 to prevent OOM
    local jobs=$(( $(nproc) / 2 ))
    [[ $jobs -gt 16 ]] && jobs=16
    [[ $jobs -lt 1 ]] && jobs=1

    log_info "Using $jobs parallel jobs ($(nproc) cores available)"
    make -j"$jobs"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install MySQL to package directory
    make DESTDIR="$pkg_dir" install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # MySQL config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/my.cnf" << EOF
# RustyPanel MySQL ${MYSQL_BRANCH} Configuration

[client]
port = 3306
socket = /run/rustypanel/mysql-${MYSQL_BRANCH}.sock
default-character-set = utf8mb4

[mysqld]
# Basic Settings
user = rustypanel
port = 3306
basedir = ${INSTALL_PREFIX}
datadir = ${DATA_DIR}
socket = /run/rustypanel/mysql-${MYSQL_BRANCH}.sock
pid-file = /run/rustypanel/mysql-${MYSQL_BRANCH}.pid

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

# Logging
log_error = /rp/logs/mysql/mysql-${MYSQL_BRANCH}-error.log
slow_query_log = 1
slow_query_log_file = /rp/logs/mysql/mysql-${MYSQL_BRANCH}-slow.log
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
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-mysql${MYSQL_VERSION_SHORT}.service" << EOF
[Unit]
Description=RustyPanel MySQL ${MYSQL_BRANCH} Database Server
After=network.target

[Service]
Type=notify
User=rustypanel
Group=rustypanel
ExecStart=${INSTALL_PREFIX}/bin/mysqld --defaults-file=${INSTALL_PREFIX}/etc/my.cnf
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
Depends: libc6, libssl3 | libssl1.1, libncurses6 | libncurses5, zlib1g, liblz4-1, libzstd1, libaio1t64 | libaio1, libnuma1
Conflicts: mysql-server
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: MySQL ${MYSQL_BRANCH} for RustyPanel
 Pre-compiled MySQL ${MYSQL_VERSION} database server.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features: InnoDB, optimized configuration for web hosting.
EOF

    # postinst
    cat > "${debian_dir}/postinst" << EOF
#!/bin/bash
set -e

INSTALL_PREFIX="${INSTALL_PREFIX}"
DATA_DIR="${DATA_DIR}"
VERSION_SHORT="${MYSQL_VERSION_SHORT}"
VERSION="${MYSQL_BRANCH}"

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create directories
mkdir -p /rp/logs/mysql
mkdir -p "\${DATA_DIR}"
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/mysql
chown -R rustypanel:rustypanel "\${DATA_DIR}"
chown rustypanel:rustypanel /run/rustypanel

# Initialize database if not exists
if [ ! -d "\${DATA_DIR}/mysql" ]; then
    echo "Initializing MySQL database..."
    "\${INSTALL_PREFIX}/bin/mysqld" \\
        --initialize-insecure \\
        --user=rustypanel \\
        --datadir="\${DATA_DIR}"
fi

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-mysql\${VERSION_SHORT}.service || true

echo "RustyPanel MySQL \${VERSION} installed successfully!"
echo "Start with: systemctl start rustypanel-mysql\${VERSION_SHORT}"
echo ""
echo "IMPORTANT: Run mysql_secure_installation after first start!"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << EOF
#!/bin/bash
set -e

systemctl stop rustypanel-mysql${MYSQL_VERSION_SHORT}.service || true
systemctl disable rustypanel-mysql${MYSQL_VERSION_SHORT}.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << EOF
#!/bin/bash
set -e

if [ "\$1" = "purge" ]; then
    echo "Note: Data directory ${DATA_DIR} was NOT removed."
    echo "Remove manually if no longer needed."
fi

systemctl daemon-reload
EOF
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
    log_info "RustyPanel MySQL Package Builder"
    log_info "==================================="
    log_info "MySQL Version:  ${MYSQL_VERSION} (${MYSQL_BRANCH})"
    log_info "Distribution:   ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:   ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_mysql
    configure_mysql
    build_mysql
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
