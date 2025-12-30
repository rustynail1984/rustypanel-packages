#!/bin/bash
set -euo pipefail

# RustyPanel NGINX Builder
# This script runs inside a Docker container

NGINX_BRANCH="${VERSION:-mainline}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_CODENAME="${DISTRO_CODENAME:-noble}"
ARCH="${ARCH:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BUILD_DIR="/tmp/nginx-build"
INSTALL_PREFIX="/rp/apps/nginx"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# NGINX version mapping
declare -A NGINX_VERSIONS=(
    ["mainline"]="1.27.3"
    ["stable"]="1.26.2"
)

NGINX_VERSION="${NGINX_VERSIONS[$NGINX_BRANCH]:-}"
if [[ -z "$NGINX_VERSION" ]]; then
    log_error "Unknown NGINX branch: $NGINX_BRANCH"
    exit 1
fi

PACKAGE_NAME="rustypanel-nginx"
PACKAGE_VERSION="${NGINX_VERSION}-1~${DISTRO}${DISTRO_VERSION}"

# OpenSSL version for HTTP/3 support
OPENSSL_VERSION="3.2.1"

install_dependencies() {
    log_info "Installing build dependencies..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        git \
        libpcre2-dev \
        zlib1g-dev \
        libgd-dev \
        libgeoip-dev \
        libxslt1-dev \
        libperl-dev \
        mercurial \
        cmake \
        golang \
        dpkg-dev \
        fakeroot
}

download_sources() {
    log_info "Downloading sources..."

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # NGINX
    log_info "Downloading NGINX ${NGINX_VERSION}..."
    wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz
    tar -xzf nginx.tar.gz

    # OpenSSL (for HTTP/3 / QUIC support)
    log_info "Downloading OpenSSL ${OPENSSL_VERSION}..."
    wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" -O openssl.tar.gz
    tar -xzf openssl.tar.gz

    # Brotli module
    log_info "Cloning Brotli module..."
    git clone --depth 1 --recursive https://github.com/google/ngx_brotli.git

    # Headers More module
    log_info "Cloning Headers More module..."
    git clone --depth 1 https://github.com/openresty/headers-more-nginx-module.git

    # Cache Purge module
    log_info "Cloning Cache Purge module..."
    git clone --depth 1 https://github.com/nginx-modules/ngx_cache_purge.git

    cd "nginx-${NGINX_VERSION}"
}

configure_nginx() {
    log_info "Configuring NGINX..."

    ./configure \
        --prefix="${INSTALL_PREFIX}" \
        --sbin-path="${INSTALL_PREFIX}/sbin/nginx" \
        --modules-path="${INSTALL_PREFIX}/modules" \
        --conf-path="${INSTALL_PREFIX}/etc/nginx.conf" \
        --error-log-path=/rp/logs/nginx/error.log \
        --http-log-path=/rp/logs/nginx/access.log \
        --pid-path=/run/rustypanel/nginx.pid \
        --lock-path=/run/rustypanel/nginx.lock \
        --http-client-body-temp-path="${INSTALL_PREFIX}/cache/client_temp" \
        --http-proxy-temp-path="${INSTALL_PREFIX}/cache/proxy_temp" \
        --http-fastcgi-temp-path="${INSTALL_PREFIX}/cache/fastcgi_temp" \
        --http-uwsgi-temp-path="${INSTALL_PREFIX}/cache/uwsgi_temp" \
        --http-scgi-temp-path="${INSTALL_PREFIX}/cache/scgi_temp" \
        --user=rustypanel \
        --group=rustypanel \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_degradation_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-http_image_filter_module=dynamic \
        --with-http_geoip_module=dynamic \
        --with-http_xslt_module=dynamic \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --with-stream_ssl_preread_module \
        --with-stream_geoip_module=dynamic \
        --with-openssl="../openssl-${OPENSSL_VERSION}" \
        --with-openssl-opt="enable-ktls" \
        --add-module=../ngx_brotli \
        --add-module=../headers-more-nginx-module \
        --add-dynamic-module=../ngx_cache_purge \
        --with-cc-opt="-O2 -g -pipe -Wall -fexceptions -fstack-protector-strong -Wno-error=unused-variable" \
        --with-ld-opt="-Wl,-z,relro -Wl,-z,now"
}

build_nginx() {
    log_info "Building NGINX (this may take a while)..."

    make -j"$(nproc)"
}

create_package_structure() {
    log_info "Creating package structure..."

    local pkg_dir="${BUILD_DIR}/package"
    local debian_dir="${pkg_dir}/DEBIAN"

    mkdir -p "$pkg_dir"
    mkdir -p "$debian_dir"

    # Install NGINX to package directory
    make DESTDIR="$pkg_dir" install

    # Create directories
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/conf.d"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/sites-available"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/sites-enabled"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/snippets"
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/cache"
    mkdir -p "${pkg_dir}/etc/systemd/system"

    # Main nginx.conf
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/nginx.conf" << 'EOF'
# RustyPanel NGINX Configuration

user rustypanel rustypanel;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/rustypanel/nginx.pid;

# Load dynamic modules
include /rp/apps/nginx/modules/*.conf;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # MIME Types
    include /rp/apps/nginx/etc/mime.types;
    default_type application/octet-stream;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    log_format json escape=json '{'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"request":"$request",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"http_referrer":"$http_referer",'
        '"http_user_agent":"$http_user_agent"'
    '}';

    access_log /rp/logs/nginx/access.log main;
    error_log /rp/logs/nginx/error.log warn;

    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1000;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml
        application/xml+rss
        application/xhtml+xml
        image/svg+xml;

    # Brotli Compression
    brotli on;
    brotli_comp_level 6;
    brotli_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml
        application/xml+rss
        application/xhtml+xml
        image/svg+xml;

    # Security Headers (can be overridden per site)
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # SSL Settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;

    # Rate Limiting
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=addr:10m;

    # FastCGI Cache
    fastcgi_cache_path /rp/apps/nginx/cache/fastcgi levels=1:2 keys_zone=FASTCGI:100m inactive=60m;
    fastcgi_cache_key "$scheme$request_method$host$request_uri";
    fastcgi_cache_use_stale error timeout invalid_header http_500;

    # Proxy Cache
    proxy_cache_path /rp/apps/nginx/cache/proxy levels=1:2 keys_zone=PROXY:100m inactive=60m;

    # Include additional configs
    include /rp/apps/nginx/etc/conf.d/*.conf;
    include /rp/apps/nginx/etc/sites-enabled/*;
}

# Stream (TCP/UDP proxy)
stream {
    include /rp/apps/nginx/etc/stream.d/*.conf;
}
EOF

    # Default site
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/sites-available/default" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;
    root /rp/wwwroot/default;
    index index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }

    # Status page (internal only)
    location /nginx_status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }
}
EOF

    # PHP snippet
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/snippets/php-fpm.conf" << 'EOF'
location ~ \.php$ {
    try_files $uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)$;
    fastcgi_pass unix:/run/rustypanel/php-fpm-8.3.sock;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_param PATH_INFO $fastcgi_path_info;
}
EOF

    # SSL snippet
    cat > "${pkg_dir}${INSTALL_PREFIX}/etc/snippets/ssl-params.conf" << 'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
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
        <p>NGINX is running successfully.</p>
    </div>
</body>
</html>
EOF

    # Enable default site
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/sites-enabled"
    ln -sf ../sites-available/default "${pkg_dir}${INSTALL_PREFIX}/etc/sites-enabled/default"

    # Create stream.d directory
    mkdir -p "${pkg_dir}${INSTALL_PREFIX}/etc/stream.d"

    # Systemd service
    cat > "${pkg_dir}/etc/systemd/system/rustypanel-nginx.service" << EOF
[Unit]
Description=RustyPanel NGINX HTTP Server
After=network.target

[Service]
Type=forking
PIDFile=/run/rustypanel/nginx.pid
ExecStartPre=${INSTALL_PREFIX}/sbin/nginx -t -q
ExecStart=${INSTALL_PREFIX}/sbin/nginx
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true
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
Depends: libc6, libpcre2-8-0, zlib1g, libgd3, libgeoip1 | libmaxminddb0, libxslt1.1
Conflicts: nginx, nginx-common, nginx-full, nginx-light
Maintainer: RustyPanel <packages@rustypanel.monity.io>
Homepage: https://rustypanel.monity.io
Description: NGINX ${NGINX_VERSION} for RustyPanel
 Pre-compiled NGINX ${NGINX_VERSION} (${NGINX_BRANCH}) web server.
 Installed to ${INSTALL_PREFIX} for RustyPanel integration.
 .
 Features:
  - HTTP/2 and HTTP/3 (QUIC) support
  - Brotli compression
  - Headers More module
  - Cache Purge module
  - GeoIP module (dynamic)
  - Image Filter module (dynamic)
  - Optimized for web hosting
EOF

    # postinst
    cat > "${debian_dir}/postinst" << 'EOF'
#!/bin/bash
set -e

INSTALL_PREFIX="/rp/apps/nginx"

# Create rustypanel user if not exists
if ! id -u rustypanel >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /rp rustypanel
fi

# Create directories
mkdir -p /rp/logs/nginx
mkdir -p /rp/wwwroot
mkdir -p /run/rustypanel
mkdir -p "${INSTALL_PREFIX}/cache/client_temp"
mkdir -p "${INSTALL_PREFIX}/cache/proxy_temp"
mkdir -p "${INSTALL_PREFIX}/cache/fastcgi_temp"
mkdir -p "${INSTALL_PREFIX}/cache/uwsgi_temp"
mkdir -p "${INSTALL_PREFIX}/cache/scgi_temp"

chown -R rustypanel:rustypanel /rp/logs/nginx
chown -R rustypanel:rustypanel /rp/wwwroot
chown -R rustypanel:rustypanel "${INSTALL_PREFIX}/cache"
chown rustypanel:rustypanel /run/rustypanel

# Reload systemd
systemctl daemon-reload
systemctl enable rustypanel-nginx.service || true

echo "RustyPanel NGINX installed successfully!"
echo "Start with: systemctl start rustypanel-nginx"
EOF
    chmod 755 "${debian_dir}/postinst"

    # prerm
    cat > "${debian_dir}/prerm" << 'EOF'
#!/bin/bash
set -e

systemctl stop rustypanel-nginx.service || true
systemctl disable rustypanel-nginx.service || true
EOF
    chmod 755 "${debian_dir}/prerm"

    # postrm
    cat > "${debian_dir}/postrm" << 'EOF'
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    rm -rf /rp/apps/nginx/cache
fi

systemctl daemon-reload
EOF
    chmod 755 "${debian_dir}/postrm"

    # conffiles
    cat > "${debian_dir}/conffiles" << EOF
${INSTALL_PREFIX}/etc/nginx.conf
${INSTALL_PREFIX}/etc/sites-available/default
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
    log_info "RustyPanel NGINX Package Builder"
    log_info "==================================="
    log_info "NGINX Version:  ${NGINX_VERSION} (${NGINX_BRANCH})"
    log_info "Distribution:   ${DISTRO} ${DISTRO_CODENAME}"
    log_info "Architecture:   ${ARCH}"
    log_info "==================================="

    install_dependencies
    download_sources
    configure_nginx
    build_nginx
    create_package_structure
    create_debian_control
    build_deb

    log_success "Build completed successfully!"
}

main "$@"
