#!/usr/bin/env bash
# ==============================================================================
# dPanel Enterprise Linux Automated 1-Click Fast Production Installer
# Targets: Ubuntu 22.04 / 24.04 LTS, Debian 12, Alpine Linux 3.19+
# Pure Rust Daemon & Axum Server Architecture
# Embedded Single-Binary Distribution (Zero external UI or SQL files needed)
# Total Installation Time: < 30 Seconds
# ==============================================================================

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Color Output Helpers
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[+]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}==================================================================${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}==================================================================${NC}\n"; }

# ------------------------------------------------------------------------------
# 1. Privileges Verification
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    log_error "dPanel installer must be executed as root. Use: sudo bash install.sh"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Existing Installation Detection & Complete Clean-up for Fresh Reinstall
# ------------------------------------------------------------------------------
DPANEL_EXISTING=false

if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet dpaneld 2>/dev/null || \
       systemctl is-active --quiet dpanel-server 2>/dev/null; then
        DPANEL_EXISTING=true
    fi
fi

if [ -f "/usr/local/bin/dpaneld" ] || [ -f "/usr/local/bin/dpanel-server" ] || [ -d "/etc/dpanel" ] || [ -f "/etc/systemd/system/dpanel-server.service" ]; then
    DPANEL_EXISTING=true
fi

DO_CLEAN_REINSTALL=false
DO_PURGE_PACKAGES=false
INSTALL_MODE="install"

# ------------------------------------------------------------------------------
# Dynamic Port & Admin Username Generators
# ------------------------------------------------------------------------------
generate_dynamic_port() {
    local candidate
    for _ in $(seq 1 50); do
        if command -v shuf &>/dev/null; then
            candidate=$(shuf -i 10000-60000 -n 1)
        else
            candidate=$(( 10000 + (RANDOM % 50000) ))
        fi
        if command -v ss &>/dev/null; then
            if ss -tuln 2>/dev/null | grep -q ":${candidate} "; then
                continue
            fi
        elif command -v netstat &>/dev/null; then
            if netstat -tuln 2>/dev/null | grep -q ":${candidate} "; then
                continue
            fi
        fi
        echo "$candidate"
        return 0
    done
    echo "2083"
}

generate_dynamic_username() {
    local suffix
    suffix=$(head -c 32 /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
    if [ -z "$suffix" ]; then
        suffix=$(date +%s | tail -c 6)
    fi
    echo "adm_${suffix}"
}

# Parse CLI arguments
CLI_ACTION=""
CLI_PORT=""
CLI_USER=""
ASSUME_YES=false

# True only when it is safe to stop and ask the operator something.
# -y always wins, so an unattended update can never block on a read even if it
# happens to be handed a terminal. Everything else falls back to TTY sniffing.
can_prompt() {
    if [ "$ASSUME_YES" = true ]; then
        return 1
    fi
    if [ -t 0 ] || [ -p /dev/stdin ]; then
        return 0
    fi
    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes|--non-interactive|--silent)
            ASSUME_YES=true
            shift
            ;;
        --fresh|--clean|--reinstall|-f|--purge|--purge-all|--deep-clean)
            CLI_ACTION="fresh"
            shift
            ;;
        --upgrade|--update|-u)
            CLI_ACTION="upgrade"
            shift
            ;;
        --port|-p)
            CLI_PORT="${2:-}"
            shift 2 2>/dev/null || shift
            ;;
        --username|--user)
            CLI_USER="${2:-}"
            shift 2 2>/dev/null || shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$DPANEL_EXISTING" = true ]; then
    INSTALL_CHOICE=""
    if [ -n "$CLI_ACTION" ]; then
        INSTALL_CHOICE="$CLI_ACTION"
    elif can_prompt; then
        echo ""
        echo -e "${BLUE}==================================================================${NC}"
        echo -e "${BLUE}        dPanel Enterprise Installation & Maintenance Mode        ${NC}"
        echo -e "${BLUE}==================================================================${NC}"
        echo -e "${YELLOW}[!] Existing dPanel installation detected on this system.${NC}"
        echo ""
        echo -e "  ${GREEN}[1] Safe Upgrade${NC}  (Zero Data Loss - Keep databases, websites, passwords)"
        echo -e "  ${RED}[2] Fresh Install${NC} (Clean Reinstall - Wipe old databases & reset everything)"
        echo ""
        read -r -p "Enter your choice [1 or 2] (Default: 1): " USER_CHOICE
        echo ""
        case "$USER_CHOICE" in
            2|"2"|"fresh"|"clean")
                INSTALL_CHOICE="fresh"
                ;;
            *)
                INSTALL_CHOICE="upgrade"
                ;;
        esac
    else
        # Default for automated background updates
        INSTALL_CHOICE="upgrade"
    fi

    if [ "$INSTALL_CHOICE" = "fresh" ]; then
        log_warn "WARNING: Fresh Install selected! All previous databases, websites, and settings will be wiped."
        if can_prompt; then
            read -r -p "Are you sure you want to completely erase existing data? [y/N]: " CONFIRM_WIPE
            if [[ ! "$CONFIRM_WIPE" =~ ^[Yy]$ ]]; then
                log_info "Operation cancelled by user. Retaining existing installation."
                exit 0
            fi
        elif [ "$ASSUME_YES" = true ]; then
            # Unreachable while INSTALL_CHOICE defaults to "upgrade" under -y, but kept as a
            # guard so unattended mode can never silently wipe data if that default changes.
            # Only an explicit --fresh may authorise a destructive reinstall unattended.
            if [ "$CLI_ACTION" != "fresh" ]; then
                log_error "Refusing to wipe an existing installation under unattended mode. Re-run with an interactive terminal to confirm, or pass --fresh explicitly."
                exit 1
            fi
            log_warn "Proceeding with Fresh Install unattended because --fresh was requested explicitly."
        fi
        DO_CLEAN_REINSTALL=true
        DO_PURGE_PACKAGES=true
        INSTALL_MODE="fresh"
    else
        log_section "Safe In-Place Upgrade Selected"
        log_info "Preserving existing databases (PostgreSQL & MariaDB), websites, and panel credentials."
        log_info "Upgrading system binaries to latest version with zero data loss..."
        DO_CLEAN_REINSTALL=false
        INSTALL_MODE="upgrade"
    fi
fi

# ------------------------------------------------------------------------------
# Resolve Active Port & Administrator Username
# ------------------------------------------------------------------------------
PANEL_PORT=""
ADMIN_USER=""

if [ "$INSTALL_MODE" = "upgrade" ] && [ -f "/etc/dpanel/.env" ]; then
    PANEL_PORT=$(grep -E '^PANEL_PORT=' /etc/dpanel/.env 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d ' ' || true)
    ADMIN_USER=$(grep -E '^INITIAL_ADMIN_USERNAME=' /etc/dpanel/.env 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d ' ' || true)
fi

# If port not set (fresh install or initial install)
if [ -z "$PANEL_PORT" ]; then
    if [ -n "$CLI_PORT" ] && [[ "$CLI_PORT" =~ ^[0-9]+$ ]] && [ "$CLI_PORT" -ge 1024 ] && [ "$CLI_PORT" -le 65535 ]; then
        PANEL_PORT="$CLI_PORT"
    else
        DYNAMIC_PORT=$(generate_dynamic_port)
        if can_prompt; then
            echo ""
            echo -e "${BLUE}------------------------------------------------------------------${NC}"
            echo -e "${GREEN}[?] Custom Portal Port Configuration${NC}"
            echo -e "    Generated Secure Dynamic Port: ${YELLOW}${DYNAMIC_PORT}${NC}"
            read -r -p "    Enter port [Press Enter to keep ${DYNAMIC_PORT}]: " USER_IN_PORT
            if [ -n "$USER_IN_PORT" ] && [[ "$USER_IN_PORT" =~ ^[0-9]+$ ]] && [ "$USER_IN_PORT" -ge 1024 ] && [ "$USER_IN_PORT" -le 65535 ]; then
                PANEL_PORT="$USER_IN_PORT"
            else
                PANEL_PORT="$DYNAMIC_PORT"
            fi
        else
            PANEL_PORT="$DYNAMIC_PORT"
        fi
    fi
fi

# If admin username not set (fresh install or initial install)
if [ -z "$ADMIN_USER" ]; then
    if [ -n "$CLI_USER" ] && [[ "$CLI_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        ADMIN_USER="$CLI_USER"
    else
        DYNAMIC_USER=$(generate_dynamic_username)
        if can_prompt; then
            echo -e "${GREEN}[?] Custom Administrator Username Configuration${NC}"
            echo -e "    Generated Dynamic Username: ${YELLOW}${DYNAMIC_USER}${NC}"
            read -r -p "    Enter username [Press Enter to keep ${DYNAMIC_USER}]: " USER_IN_USER
            if [ -n "$USER_IN_USER" ] && [[ "$USER_IN_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                ADMIN_USER="$USER_IN_USER"
            else
                ADMIN_USER="$DYNAMIC_USER"
            fi
            echo -e "${BLUE}------------------------------------------------------------------${NC}"
            echo ""
        else
            ADMIN_USER="$DYNAMIC_USER"
        fi
    fi
fi

log_info "Active Portal Port: ${PANEL_PORT}"
log_info "Active Administrator Username: ${ADMIN_USER}"

if [ "$DO_CLEAN_REINSTALL" = true ]; then
    log_section "Performing Complete System Cleanup (Zero Residue)"
    
    # 1. Stop and kill all previous Node.js apps, PM2, and NVM processes
    log_info "Stopping all previous Node.js and PM2 application processes..."
    if command -v pm2 &>/dev/null; then
        pm2 kill 2>/dev/null || true
        pm2 cleardump 2>/dev/null || true
    fi
    pkill -9 node 2>/dev/null || true
    pkill -9 pm2 2>/dev/null || true
    rm -rf /root/.pm2 /home/*/.pm2 /root/.npm /home/*/.npm /root/.nvm /home/*/.nvm 2>/dev/null || true

    # 2. Stop and disable all previous dPanel & legacy services
    log_info "Stopping and disabling previous dPanel services..."
    if command -v systemctl &>/dev/null; then
        systemctl stop dpaneld dpanel-server nginx mariadb mysql postgresql redis-server redis pure-ftpd bind9 named 2>/dev/null || true
        systemctl disable dpaneld dpanel-server 2>/dev/null || true
        rm -f /etc/systemd/system/dpaneld.service \
              /etc/systemd/system/dpanel-server.service \
              /etc/systemd/system/multi-user.target.wants/dpanel*
        systemctl daemon-reload 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service dpaneld stop 2>/dev/null || true
        rc-service dpanel-server stop 2>/dev/null || true
        rc-update del dpaneld 2>/dev/null || true
        rc-update del dpanel-server 2>/dev/null || true
        rm -f /etc/init.d/dpaneld /etc/init.d/dpanel-server
    fi

    # 3. Clean previous PostgreSQL databases, clusters, and roles
    log_info "Cleaning previous PostgreSQL database, clusters, and roles..."
    if command -v su &>/dev/null; then
        su - postgres -s /bin/sh -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'dpanel_db';\"" >/dev/null 2>&1 || true
        su - postgres -s /bin/sh -c "psql -c 'DROP DATABASE IF EXISTS dpanel_db;'" >/dev/null 2>&1 || true
        su - postgres -s /bin/sh -c "psql -c 'DROP USER IF EXISTS dpanel;'" >/dev/null 2>&1 || true
    fi

    # 4. Clean previous MariaDB/MySQL databases and users
    log_info "Cleaning previous MariaDB databases and users..."
    if command -v mysql &>/dev/null; then
        for db in $(mysql -u root -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys');" 2>/dev/null || true); do
            mysql -u root -e "DROP DATABASE IF EXISTS \`${db}\`;" 2>/dev/null || true
        done
        mysql -u root -e "DROP USER IF EXISTS 'dpanel_admin'@'localhost'; DROP USER IF EXISTS 'dpanel_admin'@'127.0.0.1'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
    fi

    # 5. Clean previous Nginx virtualhosts, sites, and SSL certificates
    log_info "Cleaning previous Nginx virtualhosts, configurations, and SSL certificates..."
    rm -rf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/* /etc/nginx/conf.d/* 2>/dev/null || true
    rm -rf /etc/ssl/dpanel/* 2>/dev/null || true
    rm -rf /var/www/dpanel-acme-challenge/* 2>/dev/null || true
    rm -rf /etc/letsencrypt/live/* /etc/letsencrypt/archive/* /etc/letsencrypt/renewal/* /etc/letsencrypt 2>/dev/null || true

    # 6. Clean website directories, phpMyAdmin, and hosted apps
    log_info "Cleaning previous website document roots and phpMyAdmin..."
    rm -rf /www/wwwroot/* /www/wwwroot /var/www/html/* /var/www/phpmyadmin /run/php/* 2>/dev/null || true

    # 7. Remove all previous dPanel files, directories, sockets, and configurations
    log_info "Removing previous configuration files, sockets, and binaries..."
    rm -rf /etc/dpanel /var/dpanel /run/dpanel /run/dpanel.sock /var/log/dpanel /tmp/dpanel_install /tmp/pma.tar.gz 2>/dev/null || true
    if [ "$SCRIPT_DIR" != "/tmp/dpanel" ] && [ "$SCRIPT_DIR" != "/tmp/dpanel-installer" ]; then
        rm -rf /tmp/dpanel /tmp/dpanel-installer 2>/dev/null || true
    fi
    rm -f /usr/local/bin/dpaneld /usr/local/bin/dpanel-server 2>/dev/null || true
    rm -rf /etc/bind/zones /etc/bind/named.conf.local /etc/pure-ftpd/pureftpd.pdb /etc/pure-ftpd/passwd /etc/pure-ftpd/conf 2>/dev/null || true

    # 8. Complete package uninstall & purge (Node.js, PM2, MariaDB, MySQL, PostgreSQL, PHP, Nginx, Redis, Pure-FTPd, BIND9, Certbot)
    log_info "Uninstalling and purging previous runtime packages (Node.js, PM2, MariaDB, MySQL, PostgreSQL, PHP, Nginx, Redis, Pure-FTPd, BIND9, Certbot)..."
    if command -v pm2 &>/dev/null; then
        pm2 kill 2>/dev/null || true
        pm2 cleardump 2>/dev/null || true
    fi
    if command -v npm &>/dev/null; then
        npm uninstall -g pm2 2>/dev/null || true
    fi
    if command -v apt-get &>/dev/null; then
        apt-get purge -y mariadb-server mariadb-client mysql-common postgresql* php* nginx* nodejs npm redis-server redis pure-ftpd bind9 bind9-utils certbot python3-certbot-nginx 2>/dev/null || true
        apt-get autoremove -y --purge 2>/dev/null || true
        rm -rf /etc/mysql /etc/php /etc/nginx /etc/redis /etc/bind /etc/pure-ftpd /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/log/nginx /var/log/mysql /var/log/redis /var/log/postgresql 2>/dev/null || true
    elif command -v apk &>/dev/null; then
        apk del postgresql16 mariadb php83-fpm nginx nodejs npm redis pure-ftpd bind certbot 2>/dev/null || true
        rm -rf /etc/mysql /etc/php /etc/nginx /var/lib/mysql /var/lib/postgresql /var/lib/redis /var/www/phpmyadmin 2>/dev/null || true
    fi

    log_info "Cleanup complete. Ready for clean fresh installation."
fi

# ------------------------------------------------------------------------------
# 3. Detect Operating System & Package Manager
# ------------------------------------------------------------------------------
log_section "Starting dPanel Enterprise Installation"

PKG_MANAGER=""
INIT_SYSTEM="systemd"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
    log_info "Detected OS: ${NAME:-$OS_ID} ${OS_VER}"
else
    log_error "Unsupported Linux distribution: /etc/os-release not found."
    exit 1
fi

case "$OS_ID" in
    ubuntu|debian)
        PKG_MANAGER="apt"
        INIT_SYSTEM="systemd"
        ;;
    alpine)
        PKG_MANAGER="apk"
        INIT_SYSTEM="openrc"
        ;;
    *)
        log_error "Unsupported Linux distribution: $OS_ID. Supported: Ubuntu 22.04+, Debian 12, Alpine Linux 3.19+"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 4. Install Minimal Lightweight Runtime Dependencies (< 30s)
# ------------------------------------------------------------------------------
log_info "Installing runtime prerequisites & web stack..."

if [ "$PKG_MANAGER" = "apt" ]; then
    # Fix arm64 repository architecture mismatch (archive.ubuntu.com does not support arm64, only ports.ubuntu.com)
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        if [ -f /etc/apt/sources.list ]; then
            sed -i 's|http://archive.ubuntu.com/ubuntu|http://ports.ubuntu.com/ubuntu-ports|g' /etc/apt/sources.list 2>/dev/null || true
            sed -i 's|http://security.ubuntu.com/ubuntu|http://ports.ubuntu.com/ubuntu-ports|g' /etc/apt/sources.list 2>/dev/null || true
        fi
        if [ -d /etc/apt/sources.list.d ]; then
            sed -i 's|http://archive.ubuntu.com/ubuntu|http://ports.ubuntu.com/ubuntu-ports|g' /etc/apt/sources.list.d/*.list 2>/dev/null || true
            sed -i 's|http://security.ubuntu.com/ubuntu|http://ports.ubuntu.com/ubuntu-ports|g' /etc/apt/sources.list.d/*.list 2>/dev/null || true
            sed -i 's|http://archive.ubuntu.com/ubuntu|http://ports.ubuntu.com/ubuntu-ports|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
        fi
    fi

    # Configure Ondrej PPA / Sury PHP repository for multi-PHP runtime support (7.4 to 8.5)
    log_info "Configuring multi-PHP runtime upstream repository..."
    rm -f /etc/apt/sources.list.d/ondrej-php.list
    apt-get install -y --no-install-recommends software-properties-common ca-certificates curl gnupg 2>/dev/null || true
    if [ "$OS_ID" = "ubuntu" ]; then
        mkdir -p /etc/apt/keyrings
        rm -f /etc/apt/keyrings/ondrej-php.gpg
        (curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x71DAEAAB4AD4CAB6" \
            | gpg --dearmor --yes --batch -o /etc/apt/keyrings/ondrej-php.gpg 2>/dev/null) || true
        UBUNTU_CODENAME="${VERSION_CODENAME:-noble}"
        PPA_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${UBUNTU_CODENAME}/Release")
        if [ "$PPA_CHECK" != "200" ]; then
            log_warn "Ondrej PPA has no release for '${UBUNTU_CODENAME}' (HTTP ${PPA_CHECK}). Falling back to 'noble'."
            UBUNTU_CODENAME="noble"
        fi
        log_info "Using Ondrej PPA codename: ${UBUNTU_CODENAME}"
        find /etc/apt/sources.list.d/ -name "*ondrej*" -exec rm -f {} \; 2>/dev/null || true
        echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${UBUNTU_CODENAME} main" > /etc/apt/sources.list.d/ondrej-php.list
    elif [ "$OS_ID" = "debian" ]; then
        mkdir -p /etc/apt/trusted.gpg.d
        curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php-sury.gpg 2>/dev/null || true
        DEB_CODENAME="${VERSION_CODENAME:-bookworm}"
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/php-sury.gpg] https://packages.sury.org/php/ ${DEB_CODENAME} main" > /etc/apt/sources.list.d/php.list
    fi

    # Fix Debian/Ubuntu 24.04 mariadb-common update-alternatives and debian-start bug
    mkdir -p /etc/mysql/conf.d /etc/mysql/mariadb.conf.d
    if [ ! -f /etc/mysql/mariadb.cnf ]; then
        cat << 'EOF' > /etc/mysql/mariadb.cnf
# The MariaDB configuration file
!includedir /etc/mysql/conf.d/
!includedir /etc/mysql/mariadb.conf.d/
EOF
    fi
    chmod 644 /etc/mysql/mariadb.cnf
    
    if [ ! -f /etc/mysql/debian-start ]; then
        cat << 'EOF' > /etc/mysql/debian-start
#!/bin/sh
exit 0
EOF
    fi
    chmod 755 /etc/mysql/debian-start 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive
    export UCF_FORCE_CONFFOLD=1
    dpkg --configure -a 2>/dev/null || true

    apt-get update -y -q 2>/dev/null || apt-get update -y || true
    if ! apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install -y --no-install-recommends \
        postgresql \
        postgresql-contrib \
        libpq5 \
        mariadb-server \
        mariadb-client \
        nginx \
        certbot \
        python3-certbot-nginx \
        php-fpm \
        php-mysql \
        php-mbstring \
        php-zip \
        php-gd \
        php-curl \
        php-xml \
        openssl \
        curl \
        ca-certificates \
        tar \
        gzip \
        bash \
        procps; then
        log_warn "Fixing dpkg package dependencies and retrying..."
        touch /etc/mysql/mariadb.cnf
        chmod 644 /etc/mysql/mariadb.cnf
        dpkg --configure -a 2>/dev/null || true
        apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install -f -y
        apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install -y --no-install-recommends \
            postgresql \
            postgresql-contrib \
            libpq5 \
            mariadb-server \
            mariadb-client \
            nginx \
            certbot \
            python3-certbot-nginx \
            php-fpm \
            php-mysql \
            php-mbstring \
            php-zip \
            php-gd \
            php-curl \
            php-xml \
            openssl \
            curl \
            ca-certificates \
            tar \
            gzip \
            bash \
            procps
    fi
elif [ "$PKG_MANAGER" = "apk" ]; then
    apk update -q
    apk add --no-cache \
        postgresql16 \
        postgresql16-contrib \
        libpq \
        mariadb \
        mariadb-client \
        nginx \
        php83-fpm \
        php83-mysqli \
        php83-mbstring \
        php83-zip \
        php83-gd \
        php83-curl \
        php83-xml \
        openssl \
        curl \
        ca-certificates \
        tar \
        gzip \
        bash \
        openrc \
        shadow \
        util-linux
fi

log_info "Runtime prerequisites ready."

# ------------------------------------------------------------------------------
# 5. Provision Enterprise Directory Layout
# ------------------------------------------------------------------------------
log_info "Configuring directory layout..."
mkdir -p /var/dpanel/backups
mkdir -p /var/dpanel/ipc
mkdir -p /var/dpanel/ssl
mkdir -p /var/dpanel/tools
mkdir -p /var/log/dpanel
mkdir -p /etc/dpanel
mkdir -p /run/dpanel
mkdir -p /var/www/phpmyadmin
mkdir -p /var/www/phpmyadmin/tmp
mkdir -p /etc/nginx/conf.d

chmod 755 /var/dpanel
chmod 750 /var/dpanel/backups
chmod 777 /var/dpanel/ipc
chmod 755 /run/dpanel
chmod 700 /etc/dpanel
chmod 777 /var/www/phpmyadmin/tmp

# ------------------------------------------------------------------------------
# 6. Multi-Architecture Binary Resolution & Deployment
# ------------------------------------------------------------------------------
log_info "Deploying dPanel core binaries..."

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    x86_64|amd64) 
        ARCH_SUBDIR="x86_64"
        ARCH_PATTERN="x86-64|x86_64|AMD64"
        ;;
    aarch64|arm64) 
        ARCH_SUBDIR="aarch64"
        ARCH_PATTERN="aarch64|ARM aarch64|ARM64"
        ;;
    *) 
        ARCH_SUBDIR="$HOST_ARCH"
        ARCH_PATTERN="$HOST_ARCH"
        ;;
esac

SRC_DPANELD=""
SRC_SERVER=""

for candidate_dir in \
    "${SCRIPT_DIR}/target/release" \
    "/opt/dpanel-src/target/release" \
    "${SCRIPT_DIR}/bin/${ARCH_SUBDIR}" \
    "${SCRIPT_DIR}/bin/${HOST_ARCH}" \
    "${SCRIPT_DIR}/bin" \
    "${SCRIPT_DIR}/dist/bin" \
    "/opt/dpanel-src/bin/${ARCH_SUBDIR}" \
    "/opt/dpanel-src/bin" \
    "/tmp/dpanel/bin" \
    "/tmp/dpanel_install/bin"; do
    if [ -f "${candidate_dir}/dpaneld" ] && [ -f "${candidate_dir}/dpanel-server" ]; then
        chmod 755 "${candidate_dir}/dpaneld" "${candidate_dir}/dpanel-server" 2>/dev/null || true
        
        # Verify architecture via static inspection without starting daemon loop
        IS_VALID_ARCH=false
        if [ "${candidate_dir}" = "${SCRIPT_DIR}/bin/${ARCH_SUBDIR}" ] || [ "${candidate_dir}" = "/opt/dpanel-src/bin/${ARCH_SUBDIR}" ]; then
            IS_VALID_ARCH=true
        elif command -v file &>/dev/null; then
            if file -b "${candidate_dir}/dpaneld" 2>/dev/null | grep -Eqi "$ARCH_PATTERN"; then
                IS_VALID_ARCH=true
            fi
        elif command -v readelf &>/dev/null; then
            if readelf -h "${candidate_dir}/dpaneld" 2>/dev/null | grep -Eqi "$ARCH_PATTERN"; then
                IS_VALID_ARCH=true
            fi
        else
            IS_VALID_ARCH=true
        fi

        if [ "$IS_VALID_ARCH" = true ]; then
            SRC_DPANELD="${candidate_dir}/dpaneld"
            SRC_SERVER="${candidate_dir}/dpanel-server"
            break
        fi
    fi
done

# If no compatible pre-built binary matches host architecture, build natively from source
if [ -z "$SRC_DPANELD" ] || [ -z "$SRC_SERVER" ]; then
    BUILD_ROOT=""
    if [ -f "${SCRIPT_DIR}/Cargo.toml" ]; then
        BUILD_ROOT="${SCRIPT_DIR}"
    elif [ -f "/opt/dpanel-src/Cargo.toml" ]; then
        BUILD_ROOT="/opt/dpanel-src"
    fi

    if [ -n "$BUILD_ROOT" ]; then
        log_info "No pre-built binary matching architecture ${HOST_ARCH}. Compiling native production binaries with Cargo..."
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev libpq-dev curl 2>/dev/null || true
        elif [ "$PKG_MANAGER" = "apk" ]; then
            apk add --no-cache build-base pkgconf openssl-dev postgresql-dev curl 2>/dev/null || true
        fi

        if ! command -v cargo &>/dev/null; then
            log_info "Setting up minimal Rust compiler toolchain..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal >/dev/null 2>&1 || true
            export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
        fi

        export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
        if command -v cargo &>/dev/null; then
            (cd "$BUILD_ROOT" && cargo build --release)
            if [ -f "${BUILD_ROOT}/target/release/dpaneld" ] && [ -f "${BUILD_ROOT}/target/release/dpanel-server" ]; then
                SRC_DPANELD="${BUILD_ROOT}/target/release/dpaneld"
                SRC_SERVER="${BUILD_ROOT}/target/release/dpanel-server"
                mkdir -p "${SCRIPT_DIR}/bin/${ARCH_SUBDIR}" 2>/dev/null || true
                cp "$SRC_DPANELD" "${SCRIPT_DIR}/bin/${ARCH_SUBDIR}/dpaneld" 2>/dev/null || true
                cp "$SRC_SERVER" "${SCRIPT_DIR}/bin/${ARCH_SUBDIR}/dpanel-server" 2>/dev/null || true
            fi
        fi
    fi
fi

if [ -n "$SRC_DPANELD" ] && [ -n "$SRC_SERVER" ]; then
    log_info "Installing binaries from ${SRC_DPANELD%/*}..."

    # 1. Stop background services if running so the binary files are unlocked
    log_info "Stopping dPanel background services prior to binary deployment..."
    if command -v systemctl &>/dev/null; then
        systemctl stop dpaneld dpanel-server 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service dpaneld stop 2>/dev/null || true
        rc-service dpanel-server stop 2>/dev/null || true
    fi
    pkill -9 -f "/usr/local/bin/dpaneld" 2>/dev/null || true
    pkill -9 -f "/usr/local/bin/dpanel-server" 2>/dev/null || true
    sleep 1

    # 2. Atomic replacement: unlink old binary or use install to prevent 'Text file busy'
    rm -f /usr/local/bin/dpaneld.old /usr/local/bin/dpanel-server.old 2>/dev/null || true
    if [ -f "/usr/local/bin/dpaneld" ]; then
        mv -f /usr/local/bin/dpaneld /usr/local/bin/dpaneld.old 2>/dev/null || rm -f /usr/local/bin/dpaneld 2>/dev/null || true
    fi
    if [ -f "/usr/local/bin/dpanel-server" ]; then
        mv -f /usr/local/bin/dpanel-server /usr/local/bin/dpanel-server.old 2>/dev/null || rm -f /usr/local/bin/dpanel-server 2>/dev/null || true
    fi

    cp -f "$SRC_DPANELD" /usr/local/bin/dpaneld
    cp -f "$SRC_SERVER" /usr/local/bin/dpanel-server
    chmod 755 /usr/local/bin/dpaneld /usr/local/bin/dpanel-server
    rm -f /usr/local/bin/dpaneld.old /usr/local/bin/dpanel-server.old 2>/dev/null || true
else
    log_error "Compatible dPanel binaries (dpanel-server, dpaneld) for ${HOST_ARCH} not found and compilation failed."
    exit 1
fi

log_info "Binaries installed successfully (UI assets & DB migrations embedded inside binary)."

# ------------------------------------------------------------------------------
# 7. PostgreSQL Fast Setup & Automatic Embedding
# ------------------------------------------------------------------------------
log_info "Setting up PostgreSQL database..."

PG_BIN=""
if [ "$PKG_MANAGER" = "apk" ]; then
    for _d in /usr/libexec/postgresql16 /usr/lib/postgresql16/bin /usr/bin; do
        if [ -x "${_d}/initdb" ]; then
            PG_BIN="${_d}"
            break
        fi
    done
    
    id -u postgres &>/dev/null || adduser -D -s /bin/sh -h /var/lib/postgresql postgres

    mkdir -p /run/postgresql /var/log
    chown -R postgres:postgres /run/postgresql
    chmod 775 /run/postgresql
    touch /var/log/postgresql.log
    chown postgres:postgres /var/log/postgresql.log

    if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
        mkdir -p /var/lib/postgresql/data
        chown -R postgres:postgres /var/lib/postgresql/data
        chmod 700 /var/lib/postgresql/data
        su - postgres -s /bin/sh -c "PATH=\"${PG_BIN}:\$PATH\" initdb -D /var/lib/postgresql/data" >/dev/null 2>&1
    fi

    if ! su - postgres -s /bin/sh -c "PATH=\"${PG_BIN}:\$PATH\" pg_ctl status -D /var/lib/postgresql/data" >/dev/null 2>&1; then
        su - postgres -s /bin/sh -c "PATH=\"${PG_BIN}:\$PATH\" pg_ctl start -D /var/lib/postgresql/data -l /var/log/postgresql.log -w -t 20" || true
    fi
elif [ "$PKG_MANAGER" = "apt" ]; then
    # Unmask PostgreSQL units if masked by cloud-init or previous package uninstall
    if command -v systemctl &>/dev/null; then
        systemctl unmask postgresql 2>/dev/null || true
        systemctl unmask postgresql@* 2>/dev/null || true
        if [ -L /etc/systemd/system/postgresql.service ]; then
            rm -f /etc/systemd/system/postgresql.service
        fi
        systemctl daemon-reload 2>/dev/null || true
    fi

    # Ensure PostgreSQL runtime socket directories
    mkdir -p /run/postgresql /var/run/postgresql
    chown -R postgres:postgres /run/postgresql /var/run/postgresql 2>/dev/null || true
    chmod 775 /run/postgresql /var/run/postgresql 2>/dev/null || true

    # Start clusters via pg_ctlcluster (Debian/Ubuntu standard)
    if command -v pg_ctlcluster &>/dev/null; then
        for _ver in 17 16 15 14 13 12; do
            if [ -d "/etc/postgresql/${_ver}/main" ] || [ -d "/var/lib/postgresql/${_ver}/main" ]; then
                pg_ctlcluster "${_ver}" main start 2>/dev/null || true
            fi
        done
    fi

    if command -v systemctl &>/dev/null; then
        systemctl enable postgresql 2>/dev/null || true
        systemctl start postgresql 2>/dev/null || true
        systemctl start postgresql@16-main 2>/dev/null || true
    else
        service postgresql start 2>/dev/null || true
    fi
fi

_pg_ready=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -c 'SELECT 1'" >/dev/null 2>&1; then
        _pg_ready=1
        break
    fi
    if [ "$_i" -eq 3 ] || [ "$_i" -eq 7 ]; then
        if command -v pg_ctlcluster &>/dev/null; then
            pg_ctlcluster 16 main start 2>/dev/null || true
        fi
        if command -v systemctl &>/dev/null; then
            systemctl start postgresql 2>/dev/null || true
        fi
    fi
    sleep 1
done

if [ "$_pg_ready" -eq 0 ]; then
    log_error "PostgreSQL did not start in time. Please check PostgreSQL service."
    exit 1
fi

log_info "PostgreSQL is online. Initializing dPanel database and user..."
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -tc \"SELECT 1 FROM pg_database WHERE datname = 'dpanel_db'\" | grep -q 1 || ${PG_BIN:+$PG_BIN/}psql -c \"CREATE DATABASE dpanel_db;\"" 2>/dev/null || true
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -tc \"SELECT 1 FROM pg_roles WHERE rolname = 'dpanel'\" | grep -q 1 || ${PG_BIN:+$PG_BIN/}psql -c \"CREATE USER dpanel WITH ENCRYPTED PASSWORD 'dpanel_secure_password';\"" 2>/dev/null || true
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -c \"GRANT ALL PRIVILEGES ON DATABASE dpanel_db TO dpanel;\"" 2>/dev/null || true
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -d dpanel_db -c \"GRANT ALL ON SCHEMA public TO dpanel;\"" 2>/dev/null || true
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -d dpanel_db -c 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO dpanel;'" 2>/dev/null || true
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -d dpanel_db -c 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO dpanel;'" 2>/dev/null || true
su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -d dpanel_db -c 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO dpanel;'" 2>/dev/null || true

log_info "Database setup completed."

# ------------------------------------------------------------------------------
# 8. MariaDB & phpMyAdmin 1-Click SSO Port 888 Setup
# ------------------------------------------------------------------------------
log_info "Setting up MariaDB & phpMyAdmin with 1-Click SSO on Port 888..."

mkdir -p /run/mysqld /var/lib/mysql /var/lib/mariadb /var/log/mysql
chage -E -1 mysql 2>/dev/null || true
usermod -s /bin/sh mysql 2>/dev/null || true
chown -R mysql:mysql /run/mysqld /var/lib/mysql /var/lib/mariadb /var/log/mysql 2>/dev/null || true
chmod 755 /run/mysqld

if command -v systemctl &>/dev/null; then
    systemctl unmask mariadb mysql 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    
    # Initialize MariaDB system database tables if missing
    if [ ! -d "/var/lib/mysql/mysql" ] && [ ! -d "/var/lib/mariadb/mysql" ]; then
        if command -v mariadb-install-db &>/dev/null; then
            su - mysql -s /bin/sh -c 'mariadb-install-db --datadir=/var/lib/mysql' >/dev/null 2>&1 || mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 || true
        elif command -v mysql_install_db &>/dev/null; then
            su - mysql -s /bin/sh -c 'mysql_install_db --datadir=/var/lib/mysql' >/dev/null 2>&1 || mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 || true
        fi
        cp -rn /var/lib/mysql/* /var/lib/mariadb/ 2>/dev/null || true
        chown -R mysql:mysql /var/lib/mysql /var/lib/mariadb 2>/dev/null || true
    fi
    
    if [ ! -f /etc/mysql/debian-start ]; then
        cat << 'EOF' > /etc/mysql/debian-start
#!/bin/sh
exit 0
EOF
    fi
    chmod 755 /etc/mysql/debian-start 2>/dev/null || true

    systemctl enable mariadb 2>/dev/null || systemctl enable mysql 2>/dev/null || true
    systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
elif command -v rc-service &>/dev/null; then
    if [ ! -d "/var/lib/mysql/mysql" ] && [ ! -d "/var/lib/mariadb/mysql" ]; then
        su - mysql -s /bin/sh -c 'mariadb-install-db --datadir=/var/lib/mysql' >/dev/null 2>&1 || mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 || true
        cp -rn /var/lib/mysql/* /var/lib/mariadb/ 2>/dev/null || true
        chown -R mysql:mysql /var/lib/mysql /var/lib/mariadb 2>/dev/null || true
    fi
    rc-service mariadb restart 2>/dev/null || true
fi

# Wait and assert MariaDB is responsive
_mysql_ready=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    if mysqladmin ping --silent 2>/dev/null || mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
        _mysql_ready=1
        break
    fi
    sleep 1
done

if [ "$_mysql_ready" -eq 1 ]; then
    log_info "MariaDB is active and ready."
    # NOTE: CREATE USER IF NOT EXISTS is a no-op when the account already exists, so a
    # stale password would never be corrected and phpMyAdmin SSO would fail with an
    # endless index.php <-> sso.php redirect loop. Drop first, then recreate, so the
    # credential always matches what databases.rs hands to the signon script.
    if ! mysql -u root -e "
        DROP USER IF EXISTS 'dpanel_admin'@'localhost';
        DROP USER IF EXISTS 'dpanel_admin'@'127.0.0.1';
        CREATE USER 'dpanel_admin'@'localhost' IDENTIFIED BY 'dPanel_MySQL_Pass_2026!';
        CREATE USER 'dpanel_admin'@'127.0.0.1' IDENTIFIED BY 'dPanel_MySQL_Pass_2026!';
        GRANT ALL PRIVILEGES ON *.* TO 'dpanel_admin'@'localhost' WITH GRANT OPTION;
        GRANT ALL PRIVILEGES ON *.* TO 'dpanel_admin'@'127.0.0.1' WITH GRANT OPTION;
        FLUSH PRIVILEGES;"; then
        log_error "Failed to provision the 'dpanel_admin' MySQL account. phpMyAdmin single sign-on will not work."
    fi
    # Verify the credential the way phpMyAdmin will actually use it (TCP, not socket).
    # MariaDB resolves 127.0.0.1 to the 'localhost' account unless skip-name-resolve is on.
    if mysql -h 127.0.0.1 -P 3306 -u dpanel_admin -p'dPanel_MySQL_Pass_2026!' -e "SELECT 1;" >/dev/null 2>&1; then
        log_info "Verified 'dpanel_admin' can authenticate over TCP (phpMyAdmin SSO ready)."
    else
        log_error "'dpanel_admin' cannot authenticate over TCP. phpMyAdmin SSO will loop instead of logging in."
    fi
else
    log_warn "MariaDB is starting up. Check status with: systemctl status mariadb"
    log_error "MariaDB never became ready; skipping 'dpanel_admin' provisioning. phpMyAdmin SSO will not work."
fi

if [ ! -f "/var/www/phpmyadmin/index.php" ] || [ ! -f "/var/www/phpmyadmin/vendor/autoload.php" ]; then
    curl -sSL https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.tar.gz -o /tmp/pma.tar.gz 2>/dev/null || true
    if [ -f /tmp/pma.tar.gz ]; then
        tar -xzf /tmp/pma.tar.gz --strip-components=1 -C /var/www/phpmyadmin
        rm -f /tmp/pma.tar.gz
    fi
fi

cat > /var/www/phpmyadmin/config.inc.php <<'PMAEOF'
<?php
declare(strict_types=1);
$cfg['blowfish_secret'] = 'dpanel_secure_blowfish_key_32_chars_ok!';
$i = 0;
$i++;
$cfg['Servers'][$i]['auth_type'] = 'signon';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = '3306';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;
$cfg['Servers'][$i]['SignonSession'] = 'SignonSession';
$cfg['Servers'][$i]['SignonScript'] = '/var/www/phpmyadmin/signon_checker.php';
$cfg['Servers'][$i]['SignonURL'] = 'sso.php';
$cfg['UploadDir'] = '';
$cfg['SaveDir'] = '';
$cfg['TempDir'] = '/var/www/phpmyadmin/tmp';
$cfg['CheckConfigurationPermissions'] = false;
PMAEOF

cat > /var/www/phpmyadmin/signon_checker.php <<'PMASIGNON'
<?php
declare(strict_types=1);

/**
 * dPanel Enterprise Session Signon Provider for phpMyAdmin
 * Seamlessly authenticates active dPanel sessions into phpMyAdmin.
 */

namespace {
    if (!function_exists('get_login_credentials')) {
        function get_login_credentials($user = '')
        {
            $sessionDir = '/var/www/phpmyadmin/tmp/sessions';
            if (!is_dir($sessionDir)) {
                @mkdir($sessionDir, 0777, true);
            }

            $cookieName = 'dpanel_pma_auth';
            if (empty($_COOKIE[$cookieName])) {
                return ['', ''];
            }

            $token = trim((string)$_COOKIE[$cookieName]);
            if (!preg_match('/^[0-9a-fA-F]{32}$/', $token)) {
                return ['', ''];
            }

            $sessionFile = $sessionDir . '/sess_' . $token . '.json';
            if (!file_exists($sessionFile)) {
                return ['', ''];
            }

            $content = @file_get_contents($sessionFile);
            if (!$content) {
                return ['', ''];
            }

            $data = @json_decode($content, true);
            if (!$data || empty($data['db_user']) || empty($data['db_pass']) || empty($data['expires_at'])) {
                @unlink($sessionFile);
                return ['', ''];
            }

            // Check expiration (inactivity timeout)
            if (time() > (int)$data['expires_at']) {
                @unlink($sessionFile);
                return ['', ''];
            }

            // Slide expiration: extend session on active use (15 mins)
            $data['expires_at'] = time() + 900;
            @file_put_contents($sessionFile, json_encode($data), LOCK_EX);

            // Provide credentials to phpMyAdmin session
            if (session_status() === PHP_SESSION_NONE) {
                @session_name('SignonSession');
                @session_start();
            }
            $_SESSION['PMA_single_signon_user'] = (string)$data['db_user'];
            $_SESSION['PMA_single_signon_password'] = (string)$data['db_pass'];
            $_SESSION['PMA_single_signon_host'] = '127.0.0.1';
            $_SESSION['PMA_single_signon_port'] = 3306;

            $GLOBALS['single_signon_user'] = (string)$data['db_user'];
            $GLOBALS['single_signon_password'] = (string)$data['db_pass'];
            $GLOBALS['single_signon_host'] = '127.0.0.1';
            $GLOBALS['single_signon_port'] = 3306;

            return [
                (string)$data['db_user'],
                (string)$data['db_pass']
            ];
        }
    }
    get_login_credentials();
}

namespace PhpMyAdmin\Plugins\Auth {
    if (!function_exists('PhpMyAdmin\Plugins\Auth\get_login_credentials')) {
        function get_login_credentials($user = '')
        {
            return \get_login_credentials($user);
        }
    }
}
PMASIGNON

mkdir -p /var/www/phpmyadmin/tmp/sessions
chown -R www-data:www-data /var/www/phpmyadmin
chmod -R 775 /var/www/phpmyadmin/tmp

cat > /var/www/phpmyadmin/panel_config.php <<PMAENV
<?php
\$panelPort = ${PANEL_PORT};
PMAENV
chown www-data:www-data /var/www/phpmyadmin/panel_config.php 2>/dev/null || true
chmod 644 /var/www/phpmyadmin/panel_config.php 2>/dev/null || true

cat > /var/www/phpmyadmin/sso.php <<'PMASSO'
<?php
declare(strict_types=1);

// Resolve dynamic panel port from panel_config.php or /etc/dpanel/.env
$panelPort = 2083;
if (file_exists(__DIR__ . '/panel_config.php')) {
    include __DIR__ . '/panel_config.php';
} elseif (file_exists('/etc/dpanel/.env')) {
    $envLines = @file('/etc/dpanel/.env', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if ($envLines) {
        foreach ($envLines as $line) {
            $line = trim($line);
            if (strpos($line, 'PANEL_PORT=') === 0) {
                $p = trim(substr($line, 11), " \t\n\r\0\x0B\"'");
                if (is_numeric($p)) { $panelPort = (int)$p; }
                break;
            }
        }
    }
}

$sessionDir = '/var/www/phpmyadmin/tmp/sessions';
if (!is_dir($sessionDir)) {
    @mkdir($sessionDir, 0777, true);
}

// Check if client already possesses an active valid session
$cookieName = 'dpanel_pma_auth';
$hasActiveSession = false;
// phpMyAdmin records why it bounced back to SignonURL; captured so a failed login can be
// reported instead of being retried forever.
$lastAuthError = '';
if (!empty($_COOKIE[$cookieName])) {
    $token = trim((string)$_COOKIE[$cookieName]);
    if (preg_match('/^[0-9a-fA-F]{32}$/', $token)) {
        $sessionFile = $sessionDir . '/sess_' . $token . '.json';
        if (file_exists($sessionFile)) {
            $content = @file_get_contents($sessionFile);
            if ($content) {
                $data = @json_decode($content, true);
                if ($data && !empty($data['db_user']) && !empty($data['db_pass']) && !empty($data['expires_at'])) {
                    if (time() <= (int)$data['expires_at']) {
                        $hasActiveSession = true;
                        if (session_status() === PHP_SESSION_NONE) {
                            @session_name('SignonSession');
                            @session_start();
                        }
                        $_SESSION['PMA_single_signon_user'] = (string)$data['db_user'];
                        $_SESSION['PMA_single_signon_password'] = (string)$data['db_pass'];
                        $_SESSION['PMA_single_signon_host'] = '127.0.0.1';
                        $_SESSION['PMA_single_signon_port'] = 3306;
                        $lastAuthError = isset($_SESSION['PMA_single_signon_error_message'])
                            ? trim((string)$_SESSION['PMA_single_signon_error_message'])
                            : '';
                        @session_write_close();
                    }
                }
            }
        }
    }
}

$ticket = isset($_GET['ticket']) ? trim((string)$_GET['ticket']) : '';

// Render a diagnosable failure page. phpMyAdmin's auth_type=signon redirects back to
// SignonURL whenever it cannot authenticate, so blindly bouncing to index.php again would
// trap the browser in an endless loop (ERR_TOO_MANY_REDIRECTS) with no explanation.
function dpanel_sso_failure(string $title, string $detail, bool $showSqlFix = false): void {
    global $panelPort;
    http_response_code(403);
    header('Content-Type: text/html; charset=utf-8');
    $host = !empty($_SERVER['HTTP_HOST']) ? explode(':', $_SERVER['HTTP_HOST'])[0] : 'localhost';
    // Built with double quotes because the page markup below lives in a single-quoted string.
    $sqlFix = "CREATE USER 'dpanel_admin'@'localhost' IDENTIFIED BY 'dPanel_MySQL_Pass_2026!';\n"
        . "CREATE USER 'dpanel_admin'@'127.0.0.1' IDENTIFIED BY 'dPanel_MySQL_Pass_2026!';\n"
        . "GRANT ALL PRIVILEGES ON *.* TO 'dpanel_admin'@'localhost' WITH GRANT OPTION;\n"
        . "GRANT ALL PRIVILEGES ON *.* TO 'dpanel_admin'@'127.0.0.1' WITH GRANT OPTION;\n"
        . "FLUSH PRIVILEGES;";
    // Only offer the account repair SQL when the database actually rejected the login,
    // otherwise it is noise that does not apply to the visitor's situation.
    $sqlBlock = $showSqlFix
        ? '<code>' . htmlspecialchars($sqlFix) . '</code>'
        : '';
    echo '<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>' . htmlspecialchars($title) . ' - dPanel phpMyAdmin SSO</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f8fafc; color: #1e293b; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 8px; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05); padding: 2.5rem; max-width: 560px; text-align: center; }
        .badge { display: inline-block; padding: 4px 12px; background: #fee2e2; color: #ef4444; font-weight: 600; font-size: 0.875rem; border-radius: 9999px; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.75rem; }
        p { color: #64748b; font-size: 0.875rem; line-height: 1.6; margin-bottom: 1rem; }
        code { display: block; background: #f1f5f9; border: 1px solid #e2e8f0; border-radius: 6px; padding: 0.75rem; margin: 1rem 0; font-size: 0.8125rem; color: #0f172a; text-align: left; white-space: pre-wrap; overflow-x: auto; }
        .btn { display: inline-block; background: #16a34a; color: #ffffff; padding: 0.625rem 1.25rem; border-radius: 6px; font-weight: 500; font-size: 0.875rem; text-decoration: none; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">403 Forbidden</div>
        <h1>' . htmlspecialchars($title) . '</h1>
        <p>' . $detail . '</p>
        ' . $sqlBlock . '
        <a href="http://' . htmlspecialchars($host) . ':' . (int)$panelPort . '/databases" class="btn">Return to dPanel</a>
    </div>
</body>
</html>';
    exit;
}

// If no ticket provided, but already authenticated, enter phpMyAdmin directly
if (empty($ticket) || !preg_match('/^[0-9a-fA-F-]{36}$/', $ticket)) {
    if ($hasActiveSession) {
        // Bounce guard: if we already sent this client to index.php during this sign-on
        // attempt and it came back here, index.php could not authenticate. Redirecting a
        // second time is what produces ERR_TOO_MANY_REDIRECTS.
        if (!empty($_COOKIE['dpanel_pma_bounce'])) {
            @setcookie('dpanel_pma_bounce', '', ['expires' => time() - 3600, 'path' => '/', 'httponly' => true, 'samesite' => 'Lax']);
            // phpMyAdmin only records a reason when the database itself refused the
            // connection. With no reason on record the earlier bounce was caused by
            // something that has since been fixed (a repaired account, an expired
            // session), so retry once instead of showing an error we cannot justify.
            // This keeps the loop bounded: a genuinely broken database still sets the
            // error and lands on the diagnostic page below.
            if ($lastAuthError === '') {
                header('Location: index.php');
                exit;
            }
            dpanel_sso_failure(
                'phpMyAdmin could not sign in',
                'The database server rejected the credentials dPanel issued, so phpMyAdmin could '
                . 'not log in. This is usually a missing or stale <code>dpanel_admin</code> MySQL '
                . 'account. phpMyAdmin reported: <strong>' . htmlspecialchars($lastAuthError) . '</strong>',
                true
            );
        }
        @setcookie('dpanel_pma_bounce', '1', ['expires' => time() + 300, 'path' => '/', 'httponly' => true, 'samesite' => 'Lax']);
        header('Location: index.php');
        exit;
    }
    http_response_code(403);
    header('Content-Type: text/html; charset=utf-8');
    echo '<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>403 Forbidden - dPanel phpMyAdmin SSO</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f8fafc; color: #1e293b; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 8px; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05); padding: 2.5rem; max-width: 440px; text-align: center; }
        .badge { display: inline-block; padding: 4px 12px; background: #fee2e2; color: #ef4444; font-weight: 600; font-size: 0.875rem; border-radius: 9999px; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.5rem; }
        p { color: #64748b; font-size: 0.875rem; line-height: 1.5; margin-bottom: 1.5rem; }
        .btn { display: inline-block; background: #16a34a; color: #ffffff; padding: 0.625rem 1.25rem; border-radius: 6px; font-weight: 500; font-size: 0.875rem; text-decoration: none; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">403 Forbidden</div>
        <h1>Authentication Required</h1>
        <p>Direct login without an active dPanel session ticket is strictly prohibited. Please log in to dPanel and launch phpMyAdmin from your control panel.</p>
        <a href="http://' . htmlspecialchars($_SERVER['HTTP_HOST'] ? explode(':', $_SERVER['HTTP_HOST'])[0] : 'localhost') . ':' . $panelPort . '/databases" class="btn">Return to dPanel</a>
    </div>
</body>
</html>';
    exit;
}

// Contact dPanel Core Server over local loopback to verify and atomically consume ticket
$verifyUrl = 'http://127.0.0.1:' . $panelPort . '/api/v1/databases/sso/verify?ticket=' . urlencode($ticket);
$response = false;
$httpCode = 0;

if (function_exists('curl_init')) {
    $ch = curl_init($verifyUrl);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 10);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 4);
    $response = curl_exec($ch);
    $httpCode = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
}

if ($httpCode !== 200 || !$response) {
    $ctx = stream_context_create([
        'http' => [
            'timeout' => 8,
            'ignore_errors' => true
        ]
    ]);
    $streamRes = @file_get_contents($verifyUrl, false, $ctx);
    if ($streamRes) {
        $response = $streamRes;
        $httpCode = 200;
    }
}

if ($httpCode !== 200 || !$response) {
    if ($hasActiveSession) {
        header('Location: index.php');
        exit;
    }
    http_response_code(403);
    header('Content-Type: text/html; charset=utf-8');
    echo '<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Session Expired - dPanel phpMyAdmin SSO</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f8fafc; color: #1e293b; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 8px; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05); padding: 2.5rem; max-width: 440px; text-align: center; }
        .badge { display: inline-block; padding: 4px 12px; background: #fee2e2; color: #ef4444; font-weight: 600; font-size: 0.875rem; border-radius: 9999px; margin-bottom: 1rem; }
        h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.5rem; }
        p { color: #64748b; font-size: 0.875rem; line-height: 1.5; margin-bottom: 1.5rem; }
        .btn { display: inline-block; background: #16a34a; color: #ffffff; padding: 0.625rem 1.25rem; border-radius: 6px; font-weight: 500; font-size: 0.875rem; text-decoration: none; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">Session Invalid</div>
        <h1>Ticket Expired or Used</h1>
        <p>This single-use authentication ticket is invalid or has already expired. Please re-launch phpMyAdmin from dPanel.</p>
        <a href="http://' . htmlspecialchars($_SERVER['HTTP_HOST'] ? explode(':', $_SERVER['HTTP_HOST'])[0] : 'localhost') . ':' . $panelPort . '/databases" class="btn">Return to dPanel</a>
    </div>
</body>
</html>';
    exit;
}

$payload = @json_decode($response, true);
if (empty($payload['valid']) || empty($payload['db_user']) || empty($payload['db_pass'])) {
    if ($hasActiveSession) {
        header('Location: index.php');
        exit;
    }
    http_response_code(403);
    die('Invalid authentication payload');
}

// Generate new authenticated session token for phpMyAdmin session checker
$sessionToken = bin2hex(random_bytes(16));
$sessionData = [
    'token' => $sessionToken,
    'db_user' => (string)$payload['db_user'],
    'db_pass' => (string)$payload['db_pass'],
    'db_name' => (string)($payload['db_name'] ?? ''),
    'created_at' => time(),
    'expires_at' => time() + 900
];

@file_put_contents($sessionDir . '/sess_' . $sessionToken . '.json', json_encode($sessionData), LOCK_EX);
@chmod($sessionDir . '/sess_' . $sessionToken . '.json', 0666);

// Set secure session cookie
@setcookie('dpanel_pma_auth', $sessionToken, [
    'expires' => time() + 86400,
    'path' => '/',
    'httponly' => true,
    'samesite' => 'Lax'
]);

// Fresh sign-on succeeded, so drop any bounce marker left by an earlier failed attempt.
@setcookie('dpanel_pma_bounce', '', ['expires' => time() - 3600, 'path' => '/', 'httponly' => true, 'samesite' => 'Lax']);

if (session_status() === PHP_SESSION_NONE) {
    @session_name('SignonSession');
    @session_start();
}
$_SESSION['PMA_single_signon_user'] = (string)$payload['db_user'];
$_SESSION['PMA_single_signon_password'] = (string)$payload['db_pass'];
$_SESSION['PMA_single_signon_host'] = '127.0.0.1';
$_SESSION['PMA_single_signon_port'] = 3306;
// Clear any error left over from a previous failed attempt.
unset($_SESSION['PMA_single_signon_error_message']);
@session_write_close();

$redirect = 'index.php' . (!empty($payload['db_name']) ? '?db=' . urlencode((string)$payload['db_name']) : '');
header('Location: ' . $redirect);
exit;
PMASSO

mkdir -p /run/php /var/run/php /var/log/php
chown -R www-data:www-data /run/php /var/run/php 2>/dev/null || true
chmod 755 /run/php /var/run/php 2>/dev/null || true

# Explicitly ensure all installed PHP-FPM services are started and unmasked
for _ver in 8.4 8.3 8.2 8.1 7.4; do
    if command -v "php-fpm${_ver}" &>/dev/null || systemctl list-unit-files "php${_ver}-fpm.service" 2>/dev/null | grep -q "php${_ver}-fpm"; then
        systemctl unmask "php${_ver}-fpm" 2>/dev/null || true
        systemctl enable --now "php${_ver}-fpm" 2>/dev/null || true
        systemctl restart "php${_ver}-fpm" 2>/dev/null || true
    fi
done
systemctl unmask php-fpm 2>/dev/null || true
systemctl enable --now php-fpm 2>/dev/null || true
systemctl restart php-fpm 2>/dev/null || true

PHP_SOCK=""
for s in $(find /run/php /var/run/php /run/php-fpm /var/run/php-fpm -name "*fpm*.sock" -o -name "*.sock" 2>/dev/null); do
    if [ -S "$s" ]; then
        PHP_SOCK="$s"
        break
    fi
done

if [ -z "$PHP_SOCK" ]; then
    for s in /run/php/php8.5-fpm.sock /run/php/php8.4-fpm.sock /run/php/php8.3-fpm.sock /run/php/php8.2-fpm.sock /run/php/php8.1-fpm.sock /run/php/php8.0-fpm.sock /run/php/php7.4-fpm.sock /run/php/php-fpm.sock /var/run/php/php8.3-fpm.sock /var/run/php/php-fpm.sock; do
        if [ -e "$s" ] || [ -S "$s" ]; then
            PHP_SOCK="$s"
            break
        fi
    done
fi

if [ -z "$PHP_SOCK" ]; then
    service php8.3-fpm restart 2>/dev/null || service php-fpm restart 2>/dev/null || true
    sleep 1
    for s in /run/php/php8.5-fpm.sock /run/php/php8.4-fpm.sock /run/php/php8.3-fpm.sock /run/php/php8.2-fpm.sock /run/php/php8.1-fpm.sock /run/php/php-fpm.sock; do
        if [ -S "$s" ]; then
            PHP_SOCK="$s"
            break
        fi
    done
fi
[ -z "$PHP_SOCK" ] && PHP_SOCK="/run/php/php8.3-fpm.sock"
ln -sf "$PHP_SOCK" /run/php/php-fpm.sock 2>/dev/null || true

mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html /www/wwwroot /var/www/dpanel-acme-challenge /var/www/dpanel-error-pages
chmod 777 /var/www/dpanel-acme-challenge 2>/dev/null || true

# Provision Standard dPanel System Error Pages (Light Theme)
for _code_info in "403:Forbidden:Access to this resource is strictly denied by server security policy.:#e11d48:#fff1f2:#fecdd3" \
                  "404:Not Found:The requested URL was not found on this server. Please verify the URL or return to the homepage.:#2563eb:#eff6ff:#bfdbfe" \
                  "500:Internal Server Error:The server encountered an internal error while processing this request.:#d97706:#fffbeb:#fde68a" \
                  "502:Bad Gateway:The gateway or upstream server failed to respond or returned an invalid response.:#d97706:#fffbeb:#fde68a" \
                  "503:Service Unavailable:The server or application is temporarily overloaded or down for maintenance.:#d97706:#fffbeb:#fde68a" \
                  "50x:Server Error:An unexpected server error occurred while fulfilling your request.:#d97706:#fffbeb:#fde68a"; do
    IFS=':' read -r _c _t _m _clr _bg _brd <<< "$_code_info"
    cat > "/var/www/dpanel-error-pages/${_c}.html" <<ERRPAGE
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${_c} ${_t} - dPanel</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background-color: #f8fafc; color: #1e293b; display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 1.5rem; }
        .card { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.05), 0 4px 6px -2px rgba(0, 0, 0, 0.025); max-width: 480px; width: 100%; padding: 2.5rem; text-align: center; }
        .badge { display: inline-block; padding: 0.35rem 1rem; border-radius: 9999px; font-size: 0.875rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 1.25rem; color: ${_clr}; background-color: ${_bg}; border: 1px solid ${_brd}; }
        h1 { font-size: 1.5rem; font-weight: 700; color: #0f172a; margin-bottom: 0.75rem; }
        p { font-size: 0.95rem; color: #64748b; line-height: 1.6; margin-bottom: 2rem; }
        .btn { display: inline-flex; align-items: center; justify-content: center; background-color: #2563eb; color: #ffffff; padding: 0.75rem 1.5rem; border-radius: 8px; font-size: 0.95rem; font-weight: 600; text-decoration: none; transition: background-color 0.15s ease-in-out; }
        .btn:hover { background-color: #1d4ed8; }
        .footer { margin-top: 2rem; padding-top: 1.25rem; border-top: 1px solid #f1f5f9; font-size: 0.8rem; color: #94a3b8; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">${_c} ${_t}</div>
        <h1>${_t}</h1>
        <p>${_m}</p>
        <a href="/" class="btn">Return to Homepage</a>
        <div class="footer">dPanel Web Server</div>
    </div>
</body>
</html>
ERRPAGE
done
chmod -R 755 /var/www/dpanel-error-pages 2>/dev/null || true
chown -R www-data:www-data /var/www/dpanel-error-pages 2>/dev/null || true

# Ensure nginx.conf includes sites-enabled
if [ -f /etc/nginx/nginx.conf ]; then
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    if ! grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    server_names_hash_bucket_size 128;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
fi

# Remove duplicate default servers from conf.d and sites-available
rm -f /etc/nginx/conf.d/phpmyadmin.conf /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null || true

# Provision Port 888 phpMyAdmin VHost
cat > /etc/nginx/sites-available/phpmyadmin.conf <<NGINXCONF
server {
    listen 888 default_server;
    listen [::]:888 default_server;
    server_name _;
    root /var/www/phpmyadmin;
    index index.php index.html;

    client_max_body_size 256M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=/var/www/phpmyadmin/:/etc/dpanel/:/tmp/:/proc/:/dev/urandom";
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
    }

    location ~ /\. {
        deny all;
    }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/phpmyadmin.conf /etc/nginx/sites-enabled/phpmyadmin.conf

# Ensure website root directory permissions
mkdir -p /www/wwwroot
chmod -R 775 /www /www/wwwroot 2>/dev/null || true
chown -R www-data:www-data /www /www/wwwroot 2>/dev/null || true



# Provision Port 80 Default Welcome Landing Page
cat > /var/www/html/index.html <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>dPanel Enterprise Web Server</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f8fafc; color: #1e293b; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .box { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; box-shadow: 0 10px 15px -3px rgba(0,0,0,0.05); padding: 3rem; max-width: 500px; text-align: center; }
        .logo { font-size: 2rem; font-weight: 700; color: #16a34a; margin-bottom: 0.5rem; }
        h2 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.75rem; }
        p { color: #64748b; font-size: 0.95rem; line-height: 1.6; margin-bottom: 2rem; }
        .btn { display: inline-block; background: #16a34a; color: #ffffff; padding: 0.75rem 1.5rem; border-radius: 8px; font-weight: 600; text-decoration: none; }
    </style>
</head>
<body>
    <div class="box">
        <div class="logo">dPanel Enterprise</div>
        <h2>Web Server is Online</h2>
        <p>The high-performance Nginx web server is operational. Manage your websites, domains, SSL, Node.js applications, and databases from your control panel.</p>
        <a href="http://127.0.0.1:${PANEL_PORT}" class="btn" id="pnlLink">Open Control Panel</a>
    </div>
    <script>
        document.getElementById('pnlLink').href = 'http://' + window.location.hostname + ':${PANEL_PORT}';
    </script>
</body>
</html>
HTMLEOF

# Generate default fallback self-signed SSL for Nginx default server
mkdir -p /etc/ssl/dpanel/certs /etc/ssl/dpanel/private
if [ ! -f /etc/ssl/dpanel/default.crt ] || [ ! -f /etc/ssl/dpanel/default.key ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/dpanel/default.key \
        -out /etc/ssl/dpanel/default.crt \
        -subj "/C=US/ST=State/L=City/O=dPanel/CN=localhost" 2>/dev/null || true
    chmod 600 /etc/ssl/dpanel/default.key 2>/dev/null || true
    chmod 644 /etc/ssl/dpanel/default.crt 2>/dev/null || true
fi

cat > /etc/nginx/sites-available/default.conf <<'DEFAULTCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html index.php;

    # ACME Challenge location
    location /.well-known/acme-challenge/ {
        root /var/www/dpanel-acme-challenge;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate /etc/ssl/dpanel/default.crt;
    ssl_certificate_key /etc/ssl/dpanel/default.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    root /var/www/html;
    index index.html index.php;

    # ACME Challenge location
    location /.well-known/acme-challenge/ {
        root /var/www/dpanel-acme-challenge;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
DEFAULTCONF

ln -sf /etc/nginx/sites-available/default.conf /etc/nginx/sites-enabled/default.conf

# Allow firewall rules
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow 888/tcp 2>/dev/null || true
    ufw allow "${PANEL_PORT}/tcp" 2>/dev/null || true
fi
if command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 888 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null || true
fi

chown -R www-data:www-data /var/www/phpmyadmin /var/www/html /var/www/dpanel-acme-challenge 2>/dev/null || true
chmod 644 /var/www/phpmyadmin/config.inc.php /var/www/phpmyadmin/sso.php /var/www/phpmyadmin/signon_checker.php /var/www/phpmyadmin/panel_config.php 2>/dev/null || true
chmod 777 /var/www/phpmyadmin/tmp /var/www/phpmyadmin/tmp/sessions 2>/dev/null || true

# Keep the single sign-on files outside the phpMyAdmin webroot as the master copy.
# The App Store "uninstall" removes /var/www/phpmyadmin wholesale and its "install" only
# unpacks the upstream tarball, so without this the SSO wiring would be destroyed by an
# uninstall and never recreated, leaving the panel pointing at a 404 /sso.php.
mkdir -p /etc/dpanel/pma-sso
cp -f /var/www/phpmyadmin/config.inc.php /var/www/phpmyadmin/sso.php \
      /var/www/phpmyadmin/signon_checker.php /var/www/phpmyadmin/panel_config.php \
      /etc/dpanel/pma-sso/ 2>/dev/null || true
# The :888 vhost is part of the same wiring, so keep a copy to restore on reinstall.
cp -f /etc/nginx/sites-available/phpmyadmin.conf /etc/dpanel/pma-sso/phpmyadmin.conf 2>/dev/null || true
chmod 600 /etc/dpanel/pma-sso/*.php 2>/dev/null || true
if command -v systemctl &>/dev/null; then
    systemctl restart php*-fpm php-fpm 2>/dev/null || true
    nginx -t && systemctl restart nginx || systemctl restart nginx || true
fi

# ------------------------------------------------------------------------------
# 9. Generate Super Admin Credentials & Environment Configuration
# ------------------------------------------------------------------------------
log_info "Configuring environment and credentials..."

if [ -f "/etc/dpanel/.env" ] && [ "$DO_CLEAN_REINSTALL" = false ]; then
    log_info "Existing /etc/dpanel/.env preserved (credentials and secrets retained)."
    EXISTING_PASS=$(grep -E '^INITIAL_ADMIN_PASSWORD=' /etc/dpanel/.env 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -n "$EXISTING_PASS" ]; then
        ADMIN_PASS="$EXISTING_PASS"
    else
        ADMIN_PASS="(Existing Password Preserved)"
    fi
else
    ADMIN_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
    JWT_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9+/=' | head -c 64)

    cat > /etc/dpanel/.env <<ENVEOF
# dPanel Enterprise Production Configuration
PANEL_ENV="production"
PANEL_PORT=${PANEL_PORT}
PANEL_HOST="0.0.0.0"
DATABASE_URL="postgres://dpanel:dpanel_secure_password@127.0.0.1:5432/dpanel_db"
JWT_SECRET="${JWT_SECRET}"
IPC_SOCKET_PATH="/run/dpanel.sock"
DAEMON_SOCKET="/run/dpanel.sock"
INITIAL_ADMIN_USERNAME="${ADMIN_USER}"
INITIAL_ADMIN_EMAIL="${ADMIN_USER}@dpanel.enterprise"
INITIAL_ADMIN_PASSWORD="${ADMIN_PASS}"
ENVEOF

    chmod 600 /etc/dpanel/.env
fi



# ------------------------------------------------------------------------------
# 10. Configure System Services (systemd / OpenRC)
# ------------------------------------------------------------------------------
log_info "Registering dPanel system services..."

if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat > /etc/systemd/system/dpaneld.service <<SERVICEEOF
[Unit]
Description=dPanel Core Privileged Daemon
After=network.target postgresql.service mariadb.service
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/dpaneld
Restart=always
RestartSec=3
EnvironmentFile=-/etc/dpanel/.env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

    cat > /etc/systemd/system/dpanel-server.service <<SERVICEEOF
[Unit]
Description=dPanel Control Plane Web Server
After=network.target dpaneld.service postgresql.service mariadb.service
Wants=dpaneld.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/dpanel-server
Restart=always
RestartSec=3
EnvironmentFile=-/etc/dpanel/.env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable dpaneld dpanel-server nginx mariadb postgresql 2>/dev/null || true
    systemctl restart mariadb 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
    systemctl restart dpaneld
    sleep 1
    systemctl restart dpanel-server

elif [ "$INIT_SYSTEM" = "openrc" ]; then
    cat > /etc/init.d/dpaneld <<'RCEOF'
#!/sbin/openrc-run
name="dpaneld"
description="dPanel Core Daemon"
command="/usr/local/bin/dpaneld"
command_background="yes"
pidfile="/run/dpaneld.pid"

depend() {
    need net postgresql
}
RCEOF

    cat > /etc/init.d/dpanel-server <<'RCEOF'
#!/sbin/openrc-run
name="dpanel-server"
description="dPanel Server"
command="/usr/local/bin/dpanel-server"
command_background="yes"
pidfile="/run/dpanel-server.pid"

depend() {
    need net dpaneld postgresql
}
RCEOF

    chmod 755 /etc/init.d/dpaneld /etc/init.d/dpanel-server
    rc-update add dpaneld default 2>/dev/null || true
    rc-update add dpanel-server default 2>/dev/null || true
    rc-service dpaneld restart
    sleep 1
    rc-service dpanel-server restart
fi

# ------------------------------------------------------------------------------
# 11. Firewall & Essential Port Provisioning (${PANEL_PORT}, 80, 443, 888, 21, 22, 53)
# ------------------------------------------------------------------------------
log_info "Configuring firewall and allowing production ports (${PANEL_PORT}, 80, 443, 888, 21, 22, 53)..."

# A. UFW (Ubuntu / Debian)
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
    ufw allow "${PANEL_PORT}/tcp" comment 'dPanel Control Plane' 2>/dev/null || true
    ufw allow 80/tcp comment 'HTTP Web' 2>/dev/null || true
    ufw allow 443/tcp comment 'HTTPS Web' 2>/dev/null || true
    ufw allow 888/tcp comment 'phpMyAdmin SSO' 2>/dev/null || true
    ufw allow 21/tcp comment 'FTP Control' 2>/dev/null || true
    ufw allow 20/tcp comment 'FTP Data' 2>/dev/null || true
    ufw allow 30000:30100/tcp comment 'FTP Passive Ports' 2>/dev/null || true
    ufw allow 53/tcp comment 'DNS TCP' 2>/dev/null || true
    ufw allow 53/udp comment 'DNS UDP' 2>/dev/null || true
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw reload 2>/dev/null || true
    fi
fi

# B. Firewalld (RHEL / AlmaLinux / Rocky / CentOS)
if command -v firewall-cmd &>/dev/null; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=22/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=888/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=21/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=20/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=30000-30100/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=53/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
fi

# C. iptables Direct Rules (Universal fallback & Oracle Cloud override)
if command -v iptables &>/dev/null; then
    for port in 22 "$PANEL_PORT" 80 443 888 21 20 53; do
        iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    done
    iptables -I INPUT 1 -p tcp --dport 30000:30100 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 12. Health Verification & Service Assertion
# ------------------------------------------------------------------------------
log_info "Verifying dPanel service health..."
sleep 2

SERVER_ONLINE=0
for attempt in 1 2 3 4 5; do
    if curl -sf "http://127.0.0.1:${PANEL_PORT}/health" >/dev/null 2>&1 || curl -sf "http://127.0.0.1:${PANEL_PORT}/" >/dev/null 2>&1; then
        SERVER_ONLINE=1
        break
    fi
    sleep 1
done

if [ "$SERVER_ONLINE" -eq 1 ]; then
    log_info "dPanel Control Plane is UP and HEALTHY."
else
    log_warn "dPanel is starting up. Check status with: systemctl status dpanel-server"
fi

# ------------------------------------------------------------------------------
# 13. Display Access Credentials & Installation Summary
# ------------------------------------------------------------------------------
PUBLIC_IP=$(curl -s4m 3 https://api.ipify.org 2>/dev/null || curl -s4m 3 https://ifconfig.me 2>/dev/null || curl -s4m 3 https://icanhazip.com 2>/dev/null || true)
INTERNAL_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || echo "127.0.0.1")

if [ -n "$PUBLIC_IP" ] && [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    DISPLAY_IP="$PUBLIC_IP"
else
    DISPLAY_IP="$INTERNAL_IP"
fi

echo ""
echo -e "${GREEN}==================================================================${NC}"
if [ "${INSTALL_MODE:-install}" = "upgrade" ]; then
echo -e "${GREEN}   dPanel Enterprise Safe Upgrade Completed Successfully!         ${NC}"
else
echo -e "${GREEN}   dPanel Enterprise Installation Completed Successfully!        ${NC}"
fi
echo -e "${GREEN}==================================================================${NC}"
echo ""
echo -e "  Panel URL:        ${BLUE}http://${DISPLAY_IP}:${PANEL_PORT}${NC}"
if [ "$DISPLAY_IP" != "$INTERNAL_IP" ] && [ -n "$INTERNAL_IP" ] && [ "$INTERNAL_IP" != "127.0.0.1" ]; then
echo -e "  Internal URL:     ${BLUE}http://${INTERNAL_IP}:${PANEL_PORT}${NC}"
fi
echo -e "  phpMyAdmin:       ${BLUE}http://${DISPLAY_IP}:888${NC}"
echo -e "  Username:         ${YELLOW}${ADMIN_USER}${NC}"
if [ "${INSTALL_MODE:-install}" = "upgrade" ]; then
echo -e "  Password:         ${YELLOW}(Existing Password Preserved)${NC}"
else
echo -e "  Password:         ${YELLOW}${ADMIN_PASS}${NC}"
fi
echo ""
echo -e "  Configuration:    ${NC}/etc/dpanel/.env${NC}"
echo -e "  Service Daemon:   ${NC}systemctl status dpaneld${NC}"
echo -e "  Service Server:   ${NC}systemctl status dpanel-server${NC}"
echo ""
echo -e "${GREEN}==================================================================${NC}"
echo ""
