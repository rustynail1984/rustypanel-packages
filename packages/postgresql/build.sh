#!/bin/bash
set -euo pipefail

# RustyPanel PostgreSQL Builder

PG_BRANCH="${VERSION:-17}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/postgresql-build"
INSTALL_PREFIX="/rp/apps/postgresql/${PG_BRANCH}"
DATA_DIR="/rp/data/postgresql/${PG_BRANCH}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# PostgreSQL version mapping
declare -A PG_VERSIONS=(
    ["17"]="17.2"
    ["16"]="16.6"
    ["15"]="15.10"
)

PG_VERSION="${PG_VERSIONS[$PG_BRANCH]:-}"
if [[ -z "$PG_VERSION" ]]; then
    log_error "Unknown PostgreSQL branch: $PG_BRANCH"
    exit 1
fi

PACKAGE_NAME="rustypanel-postgresql${PG_BRANCH}"
PACKAGE_VERSION="${PG_VERSION}-1"

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
        libreadline-dev \
        zlib1g-dev \
        libxml2-dev \
        libxslt1-dev \
        libldap2-dev \
        libpam0g-dev \
        libsystemd-dev \
        uuid-dev \
        liblz4-dev \
        libzstd-dev \
        libicu-dev \
        bison \
        flex \
        dpkg-dev \
        fakeroot
}

download_postgresql() {
    log_info "Downloading PostgreSQL ${PG_VERSION}..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    wget -q "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2" -O postgresql.tar.bz2
    tar -xjf postgresql.tar.bz2
    cd "postgresql-${PG_VERSION}"
}

configure_postgresql() {
    log_info "Configuring PostgreSQL..."

    ./configure \
        --prefix="${INSTALL_PREFIX}" \
        --with-pgport=5432 \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --with-libxml \
        --with-libxslt \
        --with-ldap \
        --with-pam \
        --with-systemd \
        --with-uuid=e2fs \
        --with-lz4 \
        --with-zstd \
        --with-icu
}

build_postgresql() {
    log_info "Building PostgreSQL..."

    # Build PostgreSQL core + contrib (skip docs - requires docbook/xsltproc)
    make -j"$(nproc)"
    make -j"$(nproc)" -C contrib
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install PostgreSQL core + contrib to package directory
    make DESTDIR="$pkg_dir" install
    make DESTDIR="$pkg_dir" -C contrib install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # PostgreSQL config
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/postgresql.conf" << EOF
# RustyPanel PostgreSQL ${PG_BRANCH} Configuration

# Connection Settings
listen_addresses = 'localhost'
port = 5432
max_connections = 100
unix_socket_directories = '/run/rustypanel'

# Memory Settings
shared_buffers = 256MB
effective_cache_size = 768MB
maintenance_work_mem = 64MB
work_mem = 4MB

# Write Ahead Log
wal_level = replica
max_wal_size = 1GB
min_wal_size = 80MB

# Query Planner
random_page_cost = 1.1
effective_io_concurrency = 200

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = '/rp/logs/postgresql'
log_filename = 'postgresql-${PG_BRANCH}-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# Locale
lc_messages = 'en_US.UTF-8'
lc_monetary = 'en_US.UTF-8'
lc_numeric = 'en_US.UTF-8'
lc_time = 'en_US.UTF-8'
default_text_search_config = 'pg_catalog.english'

# Data Directory
data_directory = '${DATA_DIR}'
EOF

    # pg_hba.conf
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/pg_hba.conf" << 'EOF'
# RustyPanel PostgreSQL Host-Based Authentication

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             all                                     peer
local   all             postgres                                peer

# IPv4 local connections
host    all             all             127.0.0.1/32            scram-sha-256

# IPv6 local connections
host    all             all             ::1/128                 scram-sha-256

# Replication connections
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
EOF

    # pg_ident.conf
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/pg_ident.conf" << 'EOF'
# PostgreSQL User Name Maps
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
EOF

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-postgresql${PG_BRANCH}.service" << EOF
[Unit]
Description=RustyPanel PostgreSQL ${PG_BRANCH} Database Server
After=network.target

[Service]
Type=notify
User=rustypanel
Group=rustypanel
Environment=PGDATA=${DATA_DIR}

ExecStartPre=${INSTALL_PREFIX}/bin/pg_isready -q || ${INSTALL_PREFIX}/bin/initdb -D ${DATA_DIR} --auth-local=peer --auth-host=scram-sha-256
ExecStart=${INSTALL_PREFIX}/bin/postgres -D ${DATA_DIR} -c config_file=${INSTALL_PREFIX}/etc/postgresql.conf -c hba_file=${INSTALL_PREFIX}/etc/pg_hba.conf -c ident_file=${INSTALL_PREFIX}/etc/pg_ident.conf
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=${INSTALL_PREFIX}/bin/pg_ctl stop -D ${DATA_DIR} -m fast

Restart=on-failure
RestartSec=5
TimeoutSec=300

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
Section: database
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${installed_size}
Depends: libc6, libssl3, libreadline8, zlib1g, libxml2, libxslt1.1, libldap-2.5-0, libpam0g, libsystemd0, libuuid1, liblz4-1, libzstd1, libicu74 | libicu72
Conflicts: postgresql, postgresql-${PG_BRANCH}
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: PostgreSQL ${PG_BRANCH} for RustyPanel
 Pre-compiled PostgreSQL ${PG_VERSION} database server.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - Full SQL compliance
  - JSONB support
  - Full-text search
  - Extensibility (extensions support)
  - Replication ready
  - LZ4 and ZSTD compression
EOF

    # postinst
    cat > "${debian_dir}/postinst" << EOF
#!/bin/bash
set -e

INSTALL_PREFIX="${INSTALL_PREFIX}"
DATA_DIR="${DATA_DIR}"
PG_BRANCH="${PG_BRANCH}"

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create directories
mkdir -p /rp/logs/postgresql
mkdir -p "\${DATA_DIR}"
mkdir -p /run/rustypanel

chown -R rustypanel:rustypanel /rp/logs/postgresql
chown -R rustypanel:rustypanel "\${DATA_DIR}"
chown rustypanel:rustypanel /run/rustypanel
chmod 700 "\${DATA_DIR}"

# Initialize database if not exists
if [ ! -f "\${DATA_DIR}/PG_VERSION" ]; then
    echo "Initializing PostgreSQL database..."
    su -s /bin/bash rustypanel -c "\${INSTALL_PREFIX}/bin/initdb -D \${DATA_DIR} --auth-local=peer --auth-host=scram-sha-256 --encoding=UTF8 --locale=en_US.UTF-8"
fi

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-postgresql\${PG_BRANCH}.service || true

echo "RustyPanel PostgreSQL \${PG_BRANCH} installed successfully!"
echo "Start with: systemctl start rustypanel-postgresql\${PG_BRANCH}"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << EOF
#!/bin/bash
set -e

systemctl stop rustypanel-postgresql${PG_BRANCH}.service || true
systemctl disable rustypanel-postgresql${PG_BRANCH}.service || true
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
${INSTALL_PREFIX}/etc/postgresql.conf
${INSTALL_PREFIX}/etc/pg_hba.conf
${INSTALL_PREFIX}/etc/pg_ident.conf
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
    log_info "======================================="
    log_info "RustyPanel PostgreSQL Package Builder"
    log_info "======================================="
    log_info "PostgreSQL Version: ${PG_VERSION} (${PG_BRANCH})"
    log_info "Distribution:       ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:       ${ARCH}"
    log_info "======================================="

    install_dependencies
    download_postgresql
    configure_postgresql
    build_postgresql
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
