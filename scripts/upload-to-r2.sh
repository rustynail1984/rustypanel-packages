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

sync_to_r2() {
    log_info "Syncing repository to R2..."

    if [[ ! -d "$REPO_DIR" ]]; then
        log_error "Repository directory not found: $REPO_DIR"
        exit 1
    fi

    # Configure AWS CLI for R2
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="auto"

    # Sync only uploads changed files (compares size/etag)
    aws s3 sync "$REPO_DIR" "s3://${R2_BUCKET_NAME}/" \
        --endpoint-url "$R2_ENDPOINT" \
        --delete \
        --size-only

    log_success "Sync completed!"
}

main() {
    log_info "==================================="
    log_info "RustyPanel R2 Uploader"
    log_info "==================================="
    log_info "Bucket: ${R2_BUCKET_NAME}"
    log_info "==================================="

    sync_to_r2

    log_success "Upload to R2 completed!"
}

main "$@"
