#!/bin/bash
set -euo pipefail

# RustyPanel Package Builder
# Usage: ./build-package.sh <package> <version> <distro> <arch>
# Example: ./build-package.sh php 8.3 ubuntu-24.04 amd64

PACKAGE="${1:-}"
VERSION="${2:-}"
DISTRO="${3:-ubuntu-24.04}"
ARCH="${4:-amd64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${PROJECT_DIR}/output"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
RustyPanel Package Builder

Usage: $0 <package> <version> [distro] [arch]

Arguments:
  package     Package name (php, mariadb, mysql, nginx, redis, nodejs)
  version     Version to build (e.g., 8.3 for PHP, 11.4 for MariaDB)
  distro      Target distribution (default: ubuntu-24.04)
              Options: ubuntu-24.04, ubuntu-22.04, debian-12
  arch        Target architecture (default: amd64)
              Options: amd64, arm64

Examples:
  $0 php 8.3
  $0 php 8.3 ubuntu-24.04 amd64
  $0 mariadb 11.4 debian-12 arm64
  $0 nginx mainline ubuntu-22.04 amd64

EOF
    exit 1
}

validate_inputs() {
    if [[ -z "$PACKAGE" ]] || [[ -z "$VERSION" ]]; then
        log_error "Package and version are required"
        usage
    fi

    if [[ ! -d "${PROJECT_DIR}/packages/${PACKAGE}" ]]; then
        log_error "Unknown package: ${PACKAGE}"
        log_info "Available packages:"
        ls -1 "${PROJECT_DIR}/packages/"
        exit 1
    fi

    case "$DISTRO" in
        ubuntu-24.04|ubuntu-22.04|debian-13|debian-12|debian-11)
            ;;
        *)
            log_error "Unsupported distro: ${DISTRO}"
            exit 1
            ;;
    esac

    case "$ARCH" in
        amd64|arm64)
            ;;
        *)
            log_error "Unsupported architecture: ${ARCH}"
            exit 1
            ;;
    esac
}

parse_distro() {
    if [[ "$DISTRO" == ubuntu-* ]]; then
        DISTRO_BASE="ubuntu"
        DISTRO_VERSION="${DISTRO#ubuntu-}"
        case "$DISTRO_VERSION" in
            "24.04") DISTRO_CODENAME="noble" ;;
            "22.04") DISTRO_CODENAME="jammy" ;;
        esac
    elif [[ "$DISTRO" == debian-* ]]; then
        DISTRO_BASE="debian"
        DISTRO_VERSION="${DISTRO#debian-}"
        case "$DISTRO_VERSION" in
            "13") DISTRO_CODENAME="trixie" ;;
            "12") DISTRO_CODENAME="bookworm" ;;
            "11") DISTRO_CODENAME="bullseye" ;;
        esac
    fi
}

build_in_docker() {
    local platform="linux/${ARCH}"
    local image="${DISTRO_BASE}:${DISTRO_VERSION}"
    local build_script="/build/packages/${PACKAGE}/build.sh"

    log_info "Building ${PACKAGE} ${VERSION} for ${DISTRO} (${ARCH})"
    log_info "Using Docker image: ${image}"

    mkdir -p "$OUTPUT_DIR"

    docker run --rm \
        --platform "$platform" \
        -v "${PROJECT_DIR}:/build" \
        -v "${OUTPUT_DIR}:/output" \
        -e "VERSION=${VERSION}" \
        -e "DISTRO=${DISTRO_BASE}" \
        -e "DISTRO_VERSION=${DISTRO_VERSION}" \
        -e "DISTRO_CODENAME=${DISTRO_CODENAME}" \
        -e "ARCH=${ARCH}" \
        -e "OUTPUT_DIR=/output" \
        "$image" \
        bash "$build_script"
}

main() {
    validate_inputs
    parse_distro

    log_info "==================================="
    log_info "RustyPanel Package Builder"
    log_info "==================================="
    log_info "Package:  ${PACKAGE}"
    log_info "Version:  ${VERSION}"
    log_info "Distro:   ${DISTRO} (${DISTRO_CODENAME})"
    log_info "Arch:     ${ARCH}"
    log_info "==================================="

    build_in_docker

    log_success "Build completed!"
    log_info "Output: ${OUTPUT_DIR}/"
    ls -la "${OUTPUT_DIR}/"*.deb 2>/dev/null || log_warn "No .deb files found"
}

main "$@"
