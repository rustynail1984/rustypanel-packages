# RustyPanel Packages

Pre-compiled Debian/Ubuntu packages for the RustyPanel App Store.

## Overview

This repository provides optimized, pre-compiled packages available as "Quick Install" option in the RustyPanel App Store.

```
┌─────────────────────────────────────────────────────────────┐
│                    Installation Options                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ⚡ Quick Install              🔧 Compile from Source       │
│   ─────────────────             ──────────────────────       │
│   • Pre-compiled                • Build from source          │
│   • ~30 seconds                 • 10-30+ minutes             │
│   • Tested & optimized          • Custom patches possible    │
│   • Automatic updates           • Custom ./configure flags   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Supported Packages

### Runtimes & Languages

| Package | Versions | Architectures |
|---------|----------|---------------|
| `rustypanel-php` | 7.4, 8.0, 8.1, 8.2, 8.3, 8.4 | amd64, arm64 |
| `rustypanel-nodejs` | 18, 20, 22 | amd64, arm64 |

### Databases

| Package | Versions | Architectures |
|---------|----------|---------------|
| `rustypanel-mariadb` | 10.11, 11.4 | amd64, arm64 |
| `rustypanel-mysql` | 8.0, 8.4 | amd64, arm64 |
| `rustypanel-redis` | 7.2, 7.4 | amd64, arm64 |
| `rustypanel-postgresql` | 15, 16, 17 | amd64, arm64 |

### Web Servers

| Package | Versions | Architectures |
|---------|----------|---------------|
| `rustypanel-nginx` | mainline, stable | amd64, arm64 |
| `rustypanel-caddy` | latest | amd64, arm64 |

## Installation

### Add APT Repository

```bash
# Import GPG key
curl -fsSL https://packages.rustypanel.dev/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/rustypanel-archive-keyring.gpg

# Add repository
echo "deb [signed-by=/usr/share/keyrings/rustypanel-archive-keyring.gpg] https://packages.rustypanel.dev/apt stable main" | sudo tee /etc/apt/sources.list.d/rustypanel.list

# Update package list
sudo apt update
```

### Install Packages

```bash
# PHP 8.3
sudo apt install rustypanel-php83

# MariaDB 11.4
sudo apt install rustypanel-mariadb114

# NGINX
sudo apt install rustypanel-nginx
```

## Directory Structure

All RustyPanel packages are installed to `/rp/apps/`:

```
/rp/
├── apps/
│   ├── php/
│   │   ├── 8.3/
│   │   │   ├── bin/
│   │   │   ├── etc/
│   │   │   ├── lib/
│   │   │   └── sbin/
│   │   └── 8.2/
│   ├── mariadb/
│   │   └── 11.4/
│   ├── nginx/
│   │   └── current/
│   └── nodejs/
│       ├── 20/
│       └── 22/
└── ...
```

## Supported Distributions

| Distribution | Version | Codename | Status |
|--------------|---------|----------|--------|
| Ubuntu | 24.04 LTS | Noble | ✅ Supported |
| Ubuntu | 22.04 LTS | Jammy | ✅ Supported |
| Debian | 13 | Trixie | ✅ Supported |
| Debian | 12 | Bookworm | ✅ Supported |
| Debian | 11 | Bullseye | ⚠️ Legacy |

## Build Process

Packages are automatically built via GitHub Actions:

1. **Trigger**: New tag or manual dispatch
2. **Build**: Docker-based build for each distro/arch combination
3. **Test**: Automatic installation tests
4. **Publish**: Upload to APT repository

### Manual Build

```bash
# Build PHP 8.3 for Ubuntu 24.04 amd64
./scripts/build-package.sh php 8.3 ubuntu-24.04 amd64

# Build PHP 8.3 for Debian 13 arm64
./scripts/build-package.sh php 8.3 debian-13 arm64

# Build all PHP versions
./scripts/build-all.sh php
```

## Package Naming Convention

```
rustypanel-{app}{major}{minor}_{version}-{build}_{arch}.deb

Examples:
rustypanel-php83_8.3.15-1_amd64.deb
rustypanel-mariadb114_11.4.3-1_arm64.deb
rustypanel-nginx_1.27.3-1_amd64.deb
```

## Configuration

Each package includes optimized default configurations for RustyPanel:

- **PHP**: php.ini optimized for web hosting, PHP-FPM pools pre-configured
- **MariaDB**: my.cnf with sensible defaults, InnoDB optimized
- **NGINX**: nginx.conf with security headers, gzip, brotli, etc.

## Differences from Distro Packages

| Feature | Distro Packages | RustyPanel Packages |
|---------|-----------------|---------------------|
| Install path | `/usr/...` | `/rp/apps/...` |
| Multi-version | Difficult | Native support |
| Updates | Distro cycle | Fast updates |
| Configuration | Standard | RustyPanel-optimized |
| PHP Extensions | Separate packages | All common ones included |

## Development

### Adding a New Package

1. Create folder under `packages/{app-name}/`
2. Create `build.sh` build script
3. Create `versions.json` with supported versions
4. Create `debian/` folder with control files
5. Add GitHub Actions workflow

### Local Testing

```bash
# Start Docker build environment
docker run -it --rm -v $(pwd):/build ubuntu:24.04 bash

# Inside container
cd /build
./packages/php/build.sh 8.3
```

## License

MIT License - see [LICENSE](LICENSE)

## Links

- [RustyPanel Main Project](https://github.com/rustypanel/rustypanel)
- [Documentation](https://docs.rustypanel.dev)
- [Issue Tracker](https://github.com/rustypanel/packages/issues)
