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

    log_success "Repository updated successfully!"
    log_info "Repository location: ${REPO_DIR}"
}

main "$@"
