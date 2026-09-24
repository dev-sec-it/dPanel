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

if [ "$DPANEL_EXISTING" = true ]; then
    if [ "${DPANEL_FORCE_REINSTALL:-0}" = "1" ]; then
        DO_CLEAN_REINSTALL=true
    elif [ -t 0 ]; then
        log_section "Existing dPanel Installation Detected"
        log_warn "A previous dPanel installation was found on this server."
        echo ""
        read -r -p "  Do you want to wipe previous data and perform a clean fresh install? [y/N]: " CONFIRM_UNINSTALL
        echo ""
        if [[ "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
            DO_CLEAN_REINSTALL=true
        else
            log_warn "Installation cancelled. Existing installation retained."
            exit 0
        fi
    fi
fi

if [ "$DO_CLEAN_REINSTALL" = true ]; then
    log_section "Performing Complete System Cleanup (Zero Residue)"
    
    # 1. Stop and kill all previous Node.js apps and PM2 processes
    log_info "Stopping all previous Node.js and PM2 application processes..."
    if command -v pm2 &>/dev/null; then
        pm2 kill 2>/dev/null || true
        pm2 cleardump 2>/dev/null || true
    fi
    pkill -9 node 2>/dev/null || true
    pkill -9 pm2 2>/dev/null || true
    rm -rf /root/.pm2 /home/*/.pm2 2>/dev/null || true

    # 2. Stop and disable all previous dPanel & legacy services
    log_info "Stopping and disabling previous dPanel services..."
    if command -v systemctl &>/dev/null; then
        systemctl stop dpaneld dpanel-server filebrowser 2>/dev/null || true
        systemctl disable dpaneld dpanel-server filebrowser 2>/dev/null || true
        rm -f /etc/systemd/system/dpaneld.service \
              /etc/systemd/system/dpanel-server.service \
              /etc/systemd/system/filebrowser.service
        systemctl daemon-reload 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service dpaneld stop 2>/dev/null || true
        rc-service dpanel-server stop 2>/dev/null || true
        rc-update del dpaneld 2>/dev/null || true
        rc-update del dpanel-server 2>/dev/null || true
        rm -f /etc/init.d/dpaneld /etc/init.d/dpanel-server
    fi

    # 3. Clean previous PostgreSQL databases and roles
    log_info "Cleaning previous PostgreSQL database and roles..."
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
    rm -rf /etc/letsencrypt/live/* /etc/letsencrypt/archive/* /etc/letsencrypt/renewal/* 2>/dev/null || true

    # 6. Clean website directories and hosted apps
    log_info "Cleaning previous website document roots..."
    rm -rf /www/wwwroot/* 2>/dev/null || true

    # 7. Remove all previous dPanel files, directories, sockets, and configurations
    log_info "Removing previous configuration files, sockets, and binaries..."
    rm -rf /etc/dpanel
    rm -rf /var/dpanel/ipc /var/dpanel/ssl /run/dpanel /run/dpanel.sock
    rm -rf /var/log/dpanel
    rm -f /usr/local/bin/dpaneld /usr/local/bin/dpanel-server /usr/local/bin/filebrowser
    rm -rf /var/www/phpmyadmin/tmp/sessions
    rm -f /var/www/phpmyadmin/sso.php /var/www/phpmyadmin/signon_checker.php

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

    # Fix Sury PHP repository missing GPG keys if present
    if [ -f /etc/apt/sources.list.d/php.list ] || grep -rq "packages.sury.org" /etc/apt/sources.list* 2>/dev/null; then
        curl -sSLo /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg 2>/dev/null || true
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
    dpkg --configure -a 2>/dev/null || true

    apt-get update -y -q 2>/dev/null || apt-get update -y || true
    if ! apt-get install -y --no-install-recommends \
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
        dpkg --configure -a || true
        apt-get install -f -y
        apt-get install -y --no-install-recommends \
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
    "${SCRIPT_DIR}/bin/${ARCH_SUBDIR}" \
    "${SCRIPT_DIR}/bin/${HOST_ARCH}" \
    "${SCRIPT_DIR}/bin" \
    "${SCRIPT_DIR}/target/release" \
    "${SCRIPT_DIR}/dist/bin" \
    "/opt/dpanel-src/bin/${ARCH_SUBDIR}" \
    "/opt/dpanel-src/bin" \
    "/opt/dpanel-src/target/release" \
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
    cp "$SRC_DPANELD" /usr/local/bin/dpaneld
    cp "$SRC_SERVER" /usr/local/bin/dpanel-server
    chmod 755 /usr/local/bin/dpaneld /usr/local/bin/dpanel-server
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

mkdir -p /run/mysqld /var/lib/mysql /var/log/mysql
chown -R mysql:mysql /run/mysqld /var/lib/mysql /var/log/mysql 2>/dev/null || true
chmod 755 /run/mysqld

if command -v systemctl &>/dev/null; then
    systemctl unmask mariadb mysql 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    
    # Initialize MariaDB data directory if missing
    if [ ! -d "/var/lib/mysql/mysql" ]; then
        if command -v mariadb-install-db &>/dev/null; then
            mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 || true
        elif command -v mysql_install_db &>/dev/null; then
            mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 || true
        fi
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
    if [ ! -d "/var/lib/mysql/mysql" ]; then
        mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 || true
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
    mysql -u root -e "CREATE USER IF NOT EXISTS 'dpanel_admin'@'localhost' IDENTIFIED BY 'dPanel_MySQL_Pass_2026!';" 2>/dev/null || true
    mysql -u root -e "CREATE USER IF NOT EXISTS 'dpanel_admin'@'127.0.0.1' IDENTIFIED BY 'dPanel_MySQL_Pass_2026!';" 2>/dev/null || true
    mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'dpanel_admin'@'localhost' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON *.* TO 'dpanel_admin'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null || true
else
    log_warn "MariaDB is starting up. Check status with: systemctl status mariadb"
fi

if [ ! -f "/var/www/phpmyadmin/index.php" ]; then
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
 * dPanel Enterprise Session Checker for phpMyAdmin
 * Enforces authenticated active session validation on EVERY request.
 */
function get_login_credentials($user)
{
    $sessionDir = '/var/www/phpmyadmin/tmp/sessions';
    if (!is_dir($sessionDir)) {
        @mkdir($sessionDir, 0700, true);
    }

    $cookieName = 'dpanel_pma_auth';
    if (empty($_COOKIE[$cookieName])) {
        return ['', ''];
    }

    $token = trim($_COOKIE[$cookieName]);
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

    // Sliding expiration: extend session on active use (15 mins)
    $data['expires_at'] = time() + 900;
    @file_put_contents($sessionFile, json_encode($data), LOCK_EX);

    return [
        $data['db_user'],
        $data['db_pass']
    ];
}
PMASIGNON

cat > /var/www/phpmyadmin/sso.php <<'PMASSO'
<?php
declare(strict_types=1);

$ticket = isset($_GET['ticket']) ? trim($_GET['ticket']) : '';

if (empty($ticket) || !preg_match('/^[0-9a-fA-F-]{36}$/', $ticket)) {
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
        .btn { display: inline-block; background: #2563eb; color: #ffffff; padding: 0.625rem 1.25rem; border-radius: 6px; font-weight: 500; font-size: 0.875rem; text-decoration: none; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">403 Forbidden</div>
        <h1>Authentication Required</h1>
        <p>Direct login without an active dPanel session ticket is strictly prohibited. Please log in to dPanel and launch phpMyAdmin from your control panel.</p>
        <a href="http://' . htmlspecialchars($_SERVER['HTTP_HOST'] ? explode(':', $_SERVER['HTTP_HOST'])[0] : 'localhost') . ':2083" class="btn">Return to dPanel</a>
    </div>
</body>
</html>';
    exit;
}

// Contact dPanel Core Server over local loopback to verify and atomically consume ticket
$ch = curl_init('http://127.0.0.1:2083/api/v1/databases/sso/verify?ticket=' . urlencode($ticket));
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 3);
$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($httpCode !== 200 || !$response) {
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
        .btn { display: inline-block; background: #2563eb; color: #ffffff; padding: 0.625rem 1.25rem; border-radius: 6px; font-weight: 500; font-size: 0.875rem; text-decoration: none; }
    </style>
</head>
<body>
    <div class="card">
        <div class="badge">Session Invalid</div>
        <h1>Ticket Expired or Used</h1>
        <p>This single-use authentication ticket is invalid or has already expired. Please re-launch phpMyAdmin from dPanel.</p>
        <a href="http://' . htmlspecialchars($_SERVER['HTTP_HOST'] ? explode(':', $_SERVER['HTTP_HOST'])[0] : 'localhost') . ':2083" class="btn">Return to dPanel</a>
    </div>
</body>
</html>';
    exit;
}

$payload = json_decode($response, true);
if (empty($payload['valid']) || empty($payload['db_user']) || empty($payload['db_pass'])) {
    http_response_code(403);
    die('Invalid authentication payload');
}

// Generate new authenticated session token for phpMyAdmin session checker
$sessionToken = bin2hex(random_bytes(16));
$sessionDir = '/var/www/phpmyadmin/tmp/sessions';
if (!is_dir($sessionDir)) {
    @mkdir($sessionDir, 0700, true);
}

$sessionData = [
    'token' => $sessionToken,
    'db_user' => $payload['db_user'],
    'db_pass' => $payload['db_pass'],
    'db_name' => $payload['db_name'] ?? '',
    'created_at' => time(),
    'expires_at' => time() + 900
];

file_put_contents($sessionDir . '/sess_' . $sessionToken . '.json', json_encode($sessionData), LOCK_EX);

// Set secure session cookie
setcookie('dpanel_pma_auth', $sessionToken, [
    'expires' => time() + 86400,
    'path' => '/',
    'httponly' => true,
    'samesite' => 'Lax'
]);

$redirect = 'index.php' . (!empty($payload['db_name']) ? '?db=' . urlencode($payload['db_name']) : '');
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
for s in /run/php/php8.5-fpm.sock /run/php/php8.4-fpm.sock /run/php/php8.3-fpm.sock /run/php/php8.2-fpm.sock /run/php/php8.1-fpm.sock /run/php/php-fpm.sock /var/run/php/php8.3-fpm.sock; do
    if [ -S "$s" ]; then
        PHP_SOCK="$s"
        break
    fi
done

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

mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html /www/wwwroot /var/www/dpanel-acme-challenge
chmod 777 /var/www/dpanel-acme-challenge 2>/dev/null || true

# Ensure nginx.conf includes sites-enabled
if [ -f /etc/nginx/nginx.conf ]; then
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
    if ! grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
        sed -i '/http {/a \    server_names_hash_bucket_size 128;' /etc/nginx/nginx.conf 2>/dev/null || true
    fi
fi

# Remove duplicate default servers from conf.d
rm -f /etc/nginx/conf.d/phpmyadmin.conf /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default 2>/dev/null || true

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

# Provision Port 80 Default Welcome Landing Page
cat > /var/www/html/index.html <<'HTMLEOF'
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
        <a href="http://127.0.0.1:2083" class="btn" id="pnlLink">Open Control Panel</a>
    </div>
    <script>
        document.getElementById('pnlLink').href = 'http://' + window.location.hostname + ':2083';
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
    ufw allow 2083/tcp 2>/dev/null || true
fi
if command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 888 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 2083 -j ACCEPT 2>/dev/null || true
fi

chown -R www-data:www-data /var/www/phpmyadmin /var/www/html /var/www/dpanel-acme-challenge 2>/dev/null || true
chmod 644 /var/www/phpmyadmin/config.inc.php /var/www/phpmyadmin/sso.php /var/www/phpmyadmin/signon_checker.php 2>/dev/null || true
if command -v systemctl &>/dev/null; then
    systemctl restart php*-fpm php-fpm 2>/dev/null || true
    nginx -t && systemctl restart nginx || systemctl restart nginx || true
fi

# ------------------------------------------------------------------------------
# 9. Generate Super Admin Credentials & Environment Configuration
# ------------------------------------------------------------------------------
log_info "Configuring environment and credentials..."

ADMIN_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
JWT_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9+/=' | head -c 64)

cat > /etc/dpanel/.env <<ENVEOF
# dPanel Enterprise Production Configuration
PANEL_ENV="production"
PANEL_PORT=2083
PANEL_HOST="0.0.0.0"
DATABASE_URL="postgres://dpanel:dpanel_secure_password@127.0.0.1:5432/dpanel_db"
JWT_SECRET="${JWT_SECRET}"
IPC_SOCKET_PATH="/run/dpanel.sock"
DAEMON_SOCKET="/run/dpanel.sock"
INITIAL_ADMIN_USERNAME="superadmin"
INITIAL_ADMIN_EMAIL="admin@dpanel.enterprise"
INITIAL_ADMIN_PASSWORD="${ADMIN_PASS}"
ENVEOF

chmod 600 /etc/dpanel/.env

# Clean up any legacy filebrowser services if present
if command -v systemctl &>/dev/null; then
    systemctl stop filebrowser 2>/dev/null || true
    systemctl disable filebrowser 2>/dev/null || true
    rm -f /etc/systemd/system/filebrowser.service /usr/local/bin/filebrowser
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
# 11. Firewall & Essential Port Provisioning (2083, 80, 443, 888, 21, 22, 53)
# ------------------------------------------------------------------------------
log_info "Configuring firewall and allowing production ports (2083, 80, 443, 888, 21, 22, 53)..."

# A. UFW (Ubuntu / Debian)
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
    ufw allow 2083/tcp comment 'dPanel Control Plane' 2>/dev/null || true
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
        firewall-cmd --permanent --add-port=2083/tcp 2>/dev/null || true
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
    for port in 22 2083 80 443 888 21 20 53; do
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
    if curl -sf http://127.0.0.1:2083/health >/dev/null 2>&1 || curl -sf http://127.0.0.1:2083/ >/dev/null 2>&1; then
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
echo -e "${GREEN}   dPanel Enterprise Installation Completed Successfully!        ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo ""
echo -e "  Panel URL:        ${BLUE}http://${DISPLAY_IP}:2083${NC}"
if [ "$DISPLAY_IP" != "$INTERNAL_IP" ] && [ -n "$INTERNAL_IP" ] && [ "$INTERNAL_IP" != "127.0.0.1" ]; then
echo -e "  Internal URL:     ${BLUE}http://${INTERNAL_IP}:2083${NC}"
fi
echo -e "  phpMyAdmin:       ${BLUE}http://${DISPLAY_IP}:888${NC}"
echo -e "  Username:         ${YELLOW}superadmin${NC}"
echo -e "  Password:         ${YELLOW}${ADMIN_PASS}${NC}"
echo ""
echo -e "  Configuration:    ${NC}/etc/dpanel/.env${NC}"
echo -e "  Service Daemon:   ${NC}systemctl status dpaneld${NC}"
echo -e "  Service Server:   ${NC}systemctl status dpanel-server${NC}"
echo ""
echo -e "${GREEN}==================================================================${NC}"
echo ""
