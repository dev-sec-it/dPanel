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
# 2. Existing Installation Detection & Cleanup
# ------------------------------------------------------------------------------
DPANEL_EXISTING=false

if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet dpaneld 2>/dev/null || \
       systemctl is-active --quiet dpanel-server 2>/dev/null; then
        DPANEL_EXISTING=true
    fi
fi

if [ -f "/usr/local/bin/dpaneld" ] || [ -f "/usr/local/bin/dpanel-server" ] || [ -d "/etc/dpanel" ]; then
    DPANEL_EXISTING=true
fi

if [ "$DPANEL_EXISTING" = true ] && [ "${DPANEL_FORCE_REINSTALL:-0}" != "1" ] && [ -t 0 ]; then
    log_section "Existing dPanel Installation Detected"
    log_warn "A previous dPanel installation was found on this server."
    echo ""
    read -r -p "  Do you want to reinstall fresh? [y/N]: " CONFIRM_UNINSTALL
    echo ""
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        log_warn "Installation cancelled. Existing installation retained."
        exit 0
    fi
fi

if [ "$DPANEL_EXISTING" = true ]; then
    log_info "Stopping existing dPanel services..."
    if command -v systemctl &>/dev/null; then
        systemctl stop dpaneld 2>/dev/null || true
        systemctl stop dpanel-server 2>/dev/null || true
        systemctl stop filebrowser 2>/dev/null || true
    elif command -v rc-service &>/dev/null; then
        rc-service dpaneld stop 2>/dev/null || true
        rc-service dpanel-server stop 2>/dev/null || true
        rc-service filebrowser stop 2>/dev/null || true
    fi
    log_info "Previous services stopped."
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
log_info "Installing runtime prerequisites..."

if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update -y -q
    apt-get install -y --no-install-recommends \
        postgresql \
        postgresql-contrib \
        libpq5 \
        openssl \
        curl \
        ca-certificates \
        tar \
        gzip \
        bash \
        procps
elif [ "$PKG_MANAGER" = "apk" ]; then
    apk update -q
    apk add --no-cache \
        postgresql16 \
        postgresql16-contrib \
        libpq \
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

chmod 755 /var/dpanel
chmod 750 /var/dpanel/backups
chmod 777 /var/dpanel/ipc
chmod 755 /run/dpanel
chmod 700 /etc/dpanel

# ------------------------------------------------------------------------------
# 6. Deploy Pre-built Binaries (Instant Copy)
# ------------------------------------------------------------------------------
log_info "Deploying pre-built dPanel binaries..."

SRC_DPANELD=""
SRC_SERVER=""

for candidate_dir in \
    "${SCRIPT_DIR}/bin" \
    "${SCRIPT_DIR}/target/release" \
    "${SCRIPT_DIR}/dist/bin" \
    "/opt/dpanel-src/bin" \
    "/opt/dpanel-src/target/release" \
    "/tmp/dpanel/bin" \
    "/tmp/dpanel_install/bin"; do
    if [ -f "${candidate_dir}/dpaneld" ] && [ -f "${candidate_dir}/dpanel-server" ]; then
        SRC_DPANELD="${candidate_dir}/dpaneld"
        SRC_SERVER="${candidate_dir}/dpanel-server"
        break
    fi
done

if [ -n "$SRC_DPANELD" ] && [ -n "$SRC_SERVER" ]; then
    log_info "Installing binaries from ${candidate_dir}..."
    cp "$SRC_DPANELD" /usr/local/bin/dpaneld
    cp "$SRC_SERVER" /usr/local/bin/dpanel-server
    chmod 755 /usr/local/bin/dpaneld /usr/local/bin/dpanel-server
else
    log_error "Pre-built dPanel binaries (dpanel-server, dpaneld) not found in ${SCRIPT_DIR}/bin."
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
    if command -v systemctl &>/dev/null; then
        systemctl start postgresql 2>/dev/null || true
    else
        service postgresql start 2>/dev/null || true
    fi
fi

_pg_ready=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    if su - postgres -s /bin/sh -c "${PG_BIN:+$PG_BIN/}psql -c 'SELECT 1'" >/dev/null 2>&1; then
        _pg_ready=1
        break
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
# 8. Generate Super Admin Credentials & Environment Configuration
# ------------------------------------------------------------------------------
log_info "Configuring environment and credentials..."

ADMIN_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)
JWT_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9+/=' | head -c 64)
FB_ADMIN_PASS=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)

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
FILEBROWSER_ADMIN_PASS="${FB_ADMIN_PASS}"
ENVEOF

chmod 600 /etc/dpanel/.env

# ------------------------------------------------------------------------------
# 9. Filebrowser Installation
# ------------------------------------------------------------------------------
log_info "Installing Filebrowser web file manager..."

if [ ! -f /usr/local/bin/filebrowser ]; then
    curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash 2>/dev/null || \
    {
        ARCH=$(uname -m)
        FB_ARCH="amd64"
        [ "$ARCH" = "aarch64" ] && FB_ARCH="arm64"
        FB_VER=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
        curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/v${FB_VER}/linux-${FB_ARCH}-filebrowser.tar.gz" -o /tmp/fb.tar.gz 2>/dev/null || true
        if [ -f /tmp/fb.tar.gz ]; then
            tar -xzf /tmp/fb.tar.gz -C /tmp/
            mv /tmp/filebrowser /usr/local/bin/filebrowser
            rm -f /tmp/fb.tar.gz
        fi
    }
fi

if [ -f /usr/local/bin/filebrowser ]; then
    chmod +x /usr/local/bin/filebrowser
    mkdir -p /etc/filebrowser /var/log/filebrowser
    
    cat > /etc/filebrowser/config.json <<FBCONF
{
  "port": 8082,
  "address": "0.0.0.0",
  "database": "/etc/filebrowser/filebrowser.db",
  "root": "/",
  "baseURL": "/filemanager",
  "log": "stdout"
}
FBCONF
    
    filebrowser config init --config /etc/filebrowser/config.json 2>/dev/null || true
    filebrowser config set --config /etc/filebrowser/config.json --auth.method=json --auth.header=X-Auth-Token --baseURL="/filemanager" --root="/" 2>/dev/null || true
    filebrowser users add admin "${FB_ADMIN_PASS}" --perm.admin=true --config /etc/filebrowser/config.json 2>/dev/null || \
    filebrowser users update admin --password "${FB_ADMIN_PASS}" --perm.admin=true --config /etc/filebrowser/config.json 2>/dev/null || true
    log_info "Filebrowser configured successfully on port 8082."
fi

# ------------------------------------------------------------------------------
# 10. Configure System Services (systemd / OpenRC)
# ------------------------------------------------------------------------------
log_info "Registering dPanel system services..."

if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat > /etc/systemd/system/dpaneld.service <<SERVICEEOF
[Unit]
Description=dPanel Core Privileged Daemon
After=network.target postgresql.service
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
After=network.target dpaneld.service postgresql.service
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

    if [ -f /usr/local/bin/filebrowser ]; then
        cat > /etc/systemd/system/filebrowser.service <<SERVICEEOF
[Unit]
Description=Filebrowser SSO Service for dPanel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/filebrowser --config /etc/filebrowser/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICEEOF
    fi

    systemctl daemon-reload
    systemctl enable dpaneld dpanel-server filebrowser 2>/dev/null || true
    systemctl restart dpaneld
    sleep 1
    systemctl restart dpanel-server
    [ -f /usr/local/bin/filebrowser ] && systemctl restart filebrowser || true

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
# 11. Health Verification & Service Assertion
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
# 12. Display Access Credentials & Installation Summary
# ------------------------------------------------------------------------------
SERVER_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || echo "YOUR_SERVER_IP")

echo ""
echo -e "${GREEN}==================================================================${NC}"
echo -e "${GREEN}   dPanel Enterprise Installation Completed Successfully!        ${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo ""
echo -e "  Panel URL:        ${BLUE}http://${SERVER_IP}:2083${NC}"
echo -e "  Username:         ${YELLOW}superadmin${NC}"
echo -e "  Password:         ${YELLOW}${ADMIN_PASS}${NC}"
echo ""
echo -e "  Configuration:    ${NC}/etc/dpanel/.env${NC}"
echo -e "  Service Daemon:   ${NC}systemctl status dpaneld${NC}"
echo -e "  Service Server:   ${NC}systemctl status dpanel-server${NC}"
echo ""
echo -e "${GREEN}==================================================================${NC}"
echo ""
