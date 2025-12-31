#!/bin/bash
set -euo pipefail

# RustyPanel R2 Uploader
# Uploads APT repository to Cloudflare R2
# Usage: ./upload-to-r2.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="${PROJECT_DIR}/repo"

# Required environment variables
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_BUCKET_NAME:?R2_BUCKET_NAME is required}"

# R2 endpoint
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

setup_aws_cli() {
    log_info "Configuring AWS CLI for R2..."

    # Configure AWS CLI for R2
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="auto"
}

sync_to_r2() {
    log_info "Syncing repository to R2..."

    if [[ ! -d "$REPO_DIR" ]]; then
        log_error "Repository directory not found: $REPO_DIR"
        exit 1
    fi

    # Sync with appropriate content types
    aws s3 sync "$REPO_DIR" "s3://${R2_BUCKET_NAME}/" \
        --endpoint-url "$R2_ENDPOINT" \
        --delete \
        --no-progress \
        --exclude "*.html" \
        --exclude "*.deb" \
        --exclude "*.gz" \
        --exclude "*.xz" \
        --exclude "*.gpg" \
        --exclude "*.key"

    # Upload HTML files with correct content type
    find "$REPO_DIR" -name "*.html" -print0 | while IFS= read -r -d '' file; do
        rel_path="${file#$REPO_DIR/}"
        log_info "  Uploading: $rel_path"
        aws s3 cp "$file" "s3://${R2_BUCKET_NAME}/${rel_path}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "text/html" \
            --no-progress
    done

    # Upload .deb files with correct content type
    find "$REPO_DIR" -name "*.deb" -print0 | while IFS= read -r -d '' file; do
        rel_path="${file#$REPO_DIR/}"
        log_info "  Uploading: $rel_path"
        aws s3 cp "$file" "s3://${R2_BUCKET_NAME}/${rel_path}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "application/vnd.debian.binary-package" \
            --no-progress
    done

    # Upload compressed files
    find "$REPO_DIR" -name "*.gz" -print0 | while IFS= read -r -d '' file; do
        rel_path="${file#$REPO_DIR/}"
        log_info "  Uploading: $rel_path"
        aws s3 cp "$file" "s3://${R2_BUCKET_NAME}/${rel_path}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "application/gzip" \
            --no-progress
    done

    find "$REPO_DIR" -name "*.xz" -print0 | while IFS= read -r -d '' file; do
        rel_path="${file#$REPO_DIR/}"
        log_info "  Uploading: $rel_path"
        aws s3 cp "$file" "s3://${R2_BUCKET_NAME}/${rel_path}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "application/x-xz" \
            --no-progress
    done

    # Upload GPG files
    find "$REPO_DIR" \( -name "*.gpg" -o -name "*.key" \) -print0 | while IFS= read -r -d '' file; do
        rel_path="${file#$REPO_DIR/}"
        log_info "  Uploading: $rel_path"
        aws s3 cp "$file" "s3://${R2_BUCKET_NAME}/${rel_path}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "application/pgp-keys" \
            --no-progress
    done

    # Upload remaining files (Packages, Release, InRelease, etc.)
    for file in "$REPO_DIR"/dists/*/Release "$REPO_DIR"/dists/*/InRelease "$REPO_DIR"/dists/*/main/binary-*/Packages; do
        [[ -f "$file" ]] || continue
        rel_path="${file#$REPO_DIR/}"
        log_info "  Uploading: $rel_path"
        aws s3 cp "$file" "s3://${R2_BUCKET_NAME}/${rel_path}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "text/plain" \
            --no-progress
    done
}

main() {
    log_info "==================================="
    log_info "RustyPanel R2 Uploader"
    log_info "==================================="
    log_info "Bucket: ${R2_BUCKET_NAME}"
    log_info "==================================="

    setup_aws_cli
    sync_to_r2

    log_success "Upload to R2 completed!"
}

main "$@"
