#!/bin/bash
set -euo pipefail

# RustyPanel APT Repository Updater
# Usage: ./update-repo.sh <packages-dir>

PACKAGES_DIR="${1:-packages}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${PROJECT_DIR}/repo"

# GPG Key ID (set via environment or use default)
GPG_KEY_ID="${GPG_KEY_ID:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Distributions to include in the repo
DISTS=("noble" "jammy" "trixie" "bookworm")
COMPONENTS=("main")
ARCHS=("amd64" "arm64")

setup_repo_structure() {
    log_info "Setting up repository structure..."

    mkdir -p "${REPO_DIR}/pool/main"

    for dist in "${DISTS[@]}"; do
        for component in "${COMPONENTS[@]}"; do
            for arch in "${ARCHS[@]}"; do
                mkdir -p "${REPO_DIR}/dists/${dist}/${component}/binary-${arch}"
            done
        done
    done
}

copy_packages() {
    log_info "Copying packages to pool..."

    find "$PACKAGES_DIR" -name "*.deb" -print0 | while IFS= read -r -d '' deb; do
        # Extract package name for organization
        pkg_name=$(dpkg-deb -f "$deb" Package | cut -d'-' -f2)
        first_letter="${pkg_name:0:1}"

        target_dir="${REPO_DIR}/pool/main/${first_letter}/${pkg_name}"
        mkdir -p "$target_dir"
        cp "$deb" "$target_dir/"
        log_info "  Added: $(basename "$deb")"
    done
}

generate_packages_file() {
    local dist="$1"
    local arch="$2"
    local packages_file="${REPO_DIR}/dists/${dist}/main/binary-${arch}/Packages"

    log_info "Generating Packages for ${dist}/${arch}..."

    # Find all .deb files and generate Packages file
    cd "$REPO_DIR"

    > "$packages_file"

    find pool -name "*.deb" | while read -r deb; do
        # Check if this deb is for the right architecture
        deb_arch=$(dpkg-deb -f "$deb" Architecture)
        if [[ "$deb_arch" == "$arch" ]] || [[ "$deb_arch" == "all" ]]; then
            dpkg-scanpackages --multiversion "$(dirname "$deb")" /dev/null 2>/dev/null | \
                sed "s|$(dirname "$deb")|pool/main|" >> "$packages_file"
        fi
    done

    # Compress
    gzip -9 -k -f "$packages_file"
    xz -k -f "$packages_file"
}

generate_release_file() {
    local dist="$1"
    local release_file="${REPO_DIR}/dists/${dist}/Release"

    log_info "Generating Release for ${dist}..."

    local date_str=$(date -Ru)
    local codename="$dist"
    local suite="stable"
    local label="RustyPanel"
    local origin="RustyPanel"
    local description="RustyPanel Package Repository"

    cat > "$release_file" << EOF
Origin: ${origin}
Label: ${label}
Suite: ${suite}
Codename: ${codename}
Date: ${date_str}
Architectures: ${ARCHS[*]}
Components: ${COMPONENTS[*]}
Description: ${description}
EOF

    # Add checksums
    cd "${REPO_DIR}/dists/${dist}"

    echo "MD5Sum:" >> "$release_file"
    find . -name "Packages*" -o -name "Release" 2>/dev/null | while read -r file; do
        [[ -f "$file" ]] || continue
        size=$(stat -c %s "$file")
        md5=$(md5sum "$file" | cut -d' ' -f1)
        echo " ${md5} ${size} ${file#./}" >> "$release_file"
    done

    echo "SHA256:" >> "$release_file"
    find . -name "Packages*" -o -name "Release" 2>/dev/null | while read -r file; do
        [[ -f "$file" ]] || continue
        size=$(stat -c %s "$file")
        sha256=$(sha256sum "$file" | cut -d' ' -f1)
        echo " ${sha256} ${size} ${file#./}" >> "$release_file"
    done

    cd "$PROJECT_DIR"
}

sign_release() {
    local dist="$1"
    local release_file="${REPO_DIR}/dists/${dist}/Release"
    local inrelease_file="${REPO_DIR}/dists/${dist}/InRelease"
    local release_gpg="${REPO_DIR}/dists/${dist}/Release.gpg"

    if [[ -z "$GPG_KEY_ID" ]]; then
        log_info "Skipping GPG signing (no GPG_KEY_ID set)"
        return
    fi

    log_info "Signing Release for ${dist}..."

    # Detached signature
    gpg --default-key "$GPG_KEY_ID" \
        --armor \
        --detach-sign \
        --output "$release_gpg" \
        "$release_file"

    # Inline signature (InRelease)
    gpg --default-key "$GPG_KEY_ID" \
        --armor \
        --sign \
        --clearsign \
        --output "$inrelease_file" \
        "$release_file"
}

export_public_key() {
    if [[ -z "$GPG_KEY_ID" ]]; then
        return
    fi

    log_info "Exporting public key..."
    gpg --armor --export "$GPG_KEY_ID" > "${REPO_DIR}/gpg.key"
}

generate_directory_index() {
    local dir="$1"
    local rel_path="${dir#$REPO_DIR}"
    rel_path="${rel_path#/}"

    local index_file="${dir}/index.html"
    local title="Index of /${rel_path}"

    if [[ -z "$rel_path" ]]; then
        # Skip root directory - has its own index.html
        return
    fi

    log_info "Generating index for /${rel_path}..."

    cat > "$index_file" << 'HEADER'
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
HEADER

    echo "    <title>${title}</title>" >> "$index_file"

    cat >> "$index_file" << 'STYLE'
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; background: #1a1d21; color: #f5f5f4; max-width: 900px; margin: 0 auto; padding: 20px; }
        h1 { color: #e45a27; font-size: 1.5rem; margin-bottom: 1rem; }
        .breadcrumb { margin-bottom: 1rem; font-size: 0.9rem; }
        .breadcrumb a { color: #e45a27; text-decoration: none; }
        .breadcrumb a:hover { text-decoration: underline; }
        table { width: 100%; border-collapse: collapse; background: #252a31; border-radius: 8px; overflow: hidden; }
        th, td { padding: 10px 15px; text-align: left; border-bottom: 1px solid #1a1d21; }
        th { background: #1e2227; color: #888; font-weight: 500; font-size: 0.85rem; }
        tr:last-child td { border-bottom: none; }
        tr:hover { background: #2a3038; }
        a { color: #e45a27; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .size { color: #888; font-family: monospace; }
        .date { color: #888; font-size: 0.9rem; }
        .icon { margin-right: 8px; }
    </style>
</head>
<body>
STYLE

    echo "    <h1>${title}</h1>" >> "$index_file"

    # Generate breadcrumb
    echo '    <div class="breadcrumb">' >> "$index_file"
    echo -n '        <a href="/">Home</a>' >> "$index_file"

    local path_parts=""
    IFS='/' read -ra PARTS <<< "$rel_path"
    for part in "${PARTS[@]}"; do
        path_parts="${path_parts}/${part}"
        echo -n " / <a href=\"${path_parts}/\">${part}</a>" >> "$index_file"
    done
    echo '' >> "$index_file"
    echo '    </div>' >> "$index_file"

    cat >> "$index_file" << 'TABLE_START'
    <table>
        <thead>
            <tr>
                <th>Name</th>
                <th>Size</th>
                <th>Last Modified</th>
            </tr>
        </thead>
        <tbody>
TABLE_START

    # Parent directory link
    if [[ -n "$rel_path" ]]; then
        echo '            <tr><td><span class="icon">📁</span><a href="../">../</a></td><td class="size">-</td><td class="date">-</td></tr>' >> "$index_file"
    fi

    # List directories first
    for item in "$dir"/*; do
        [[ -e "$item" ]] || continue
        local name=$(basename "$item")
        [[ "$name" == "index.html" ]] && continue

        if [[ -d "$item" ]]; then
            local mtime=$(stat -c "%Y" "$item" 2>/dev/null || echo "0")
            local date_str=$(date -d "@$mtime" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "-")
            echo "            <tr><td><span class=\"icon\">📁</span><a href=\"${name}/\">${name}/</a></td><td class=\"size\">-</td><td class=\"date\">${date_str}</td></tr>" >> "$index_file"
        fi
    done

    # List files
    for item in "$dir"/*; do
        [[ -e "$item" ]] || continue
        local name=$(basename "$item")
        [[ "$name" == "index.html" ]] && continue

        if [[ -f "$item" ]]; then
            local size=$(stat -c "%s" "$item" 2>/dev/null || echo "0")
            local mtime=$(stat -c "%Y" "$item" 2>/dev/null || echo "0")
            local date_str=$(date -d "@$mtime" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "-")

            # Human readable size
            if [[ $size -ge 1073741824 ]]; then
                size_str=$(echo "scale=1; $size/1073741824" | bc)"G"
            elif [[ $size -ge 1048576 ]]; then
                size_str=$(echo "scale=1; $size/1048576" | bc)"M"
            elif [[ $size -ge 1024 ]]; then
                size_str=$(echo "scale=1; $size/1024" | bc)"K"
            else
                size_str="${size}B"
            fi

            # Icon based on extension
            local icon="📄"
            case "$name" in
                *.deb) icon="📦" ;;
                *.gz|*.xz|*.bz2) icon="🗜️" ;;
                *.gpg|*.asc) icon="🔐" ;;
                *.key) icon="🔑" ;;
            esac

            echo "            <tr><td><span class=\"icon\">${icon}</span><a href=\"${name}\">${name}</a></td><td class=\"size\">${size_str}</td><td class=\"date\">${date_str}</td></tr>" >> "$index_file"
        fi
    done

    cat >> "$index_file" << 'FOOTER'
        </tbody>
    </table>
</body>
</html>
FOOTER
}

generate_all_indexes() {
    log_info "Generating directory indexes..."

    # Find all directories and generate index.html for each
    find "$REPO_DIR" -type d | while read -r dir; do
        generate_directory_index "$dir"
    done
}

main() {
    log_info "==================================="
    log_info "RustyPanel Repository Updater"
    log_info "==================================="

    if [[ ! -d "$PACKAGES_DIR" ]]; then
        log_error "Packages directory not found: $PACKAGES_DIR"
        exit 1
    fi

    setup_repo_structure
    copy_packages

    for dist in "${DISTS[@]}"; do
        for arch in "${ARCHS[@]}"; do
            generate_packages_file "$dist" "$arch"
        done
        generate_release_file "$dist"
        sign_release "$dist"
    done

    export_public_key
    generate_all_indexes

    log_success "Repository updated successfully!"
    log_info "Repository location: ${REPO_DIR}"
}

main "$@"
