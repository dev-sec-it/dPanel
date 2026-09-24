# dPanel Enterprise — Next-Generation Linux Cloud Control Plane
### Engineered by DEV SEC IT

[![DEV SEC IT](https://img.shields.io/badge/Engineered%20By-DEV%20SEC%20IT-0ea5e9?style=for-the-badge&logo=shield)](https://devsecit.com)
[![Rust](https://img.shields.io/badge/Rust-1.78%2B-black?style=for-the-badge&logo=rust)](https://www.rust-lang.org/)
[![React](https://img.shields.io/badge/React-19.0-61dafb?style=for-the-badge&logo=react)](https://react.dev/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?style=for-the-badge&logo=postgresql)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/License-Proprietary%20%2F%20Open%20Source%20Target-green?style=for-the-badge)](https://github.com/devsecit/dPanel)

> **Open Source Milestone**: This enterprise cloud panel was engineered by **DEV SEC IT**. The complete codebase will be released under a fully permissive open-source license once the repository reaches **100 GitHub Stars (100 ⭐)**!

---

## 1. Executive Summary & Architecture Overview

**dPanel Enterprise** is a high-performance, single-binary Linux web hosting and server orchestration control plane. Engineered to replace legacy, resource-heavy panels (such as cPanel, Plesk, and aaPanel), dPanel delivers microsecond response times with a minimal RAM footprint (< 40MB base idle).

### Core Architectural Pillars

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        dPanel Enterprise Architecture                  │
├────────────────────────────────┬───────────────────────────────────────┤
│    dpanel-server (Control Plane)│   dpaneld (Privileged Core Daemon)    │
│    • Axum 0.7 Web Framework    │   • Pure Rust System Worker           │
│    • Embedded UI (rust-embed)  │   • Process & Service Management      │
│    • Embedded DB (sqlx::migrate)│   • Nginx, PHP, Node.js, PM2, Docker  │
│    • JWT Auth & RBAC Guard     │   • Pure-FTPd, BIND9, Fail2ban, UFW   │
└────────────────┬───────────────┴───────────────────┬───────────────────┘
                 │                                   │
                 └─────────► Unix IPC Socket ◄───────┘
                        (/run/dpanel.sock)
```

1. **Single-Binary Self-Contained Deployment**:
   - The entire React 19 frontend bundle (HTML, JavaScript, CSS, SVGs, Fonts) is compiled directly into the `dpanel-server` ELF binary via `rust-embed`.
   - All PostgreSQL database schema migrations are compiled into binary memory via `sqlx::migrate!()` and applied automatically on boot.
   - **Zero external static or migration files on the host disk** — completely tamper-proof and immune to client-side disk file modifications.

2. **Dual-Tier Privilege Separation**:
   - **`dpanel-server` (Port 2083)**: Handles REST API endpoints, JWT authentication, and serves the embedded UI.
   - **`dpaneld` (Daemon)**: Runs isolated in the background with privileged capabilities, executing system actions via Unix Domain Sockets (`/run/dpanel.sock`).

---

## 2. Features Matrix & Implementation Checklist

### Core Features (Current Production Release)

- [x] **Single-Binary Zero-Disk Footprint**: Web UI and database migrations baked directly inside the executable.
- [x] **Web & Domain Management**:
  - [x] Nginx Virtual Hosts reverse proxy & static site routing
  - [x] Automated Let's Encrypt SSL generation (HTTP-01 ACME) & auto-renewal
  - [x] Custom SSL/TLS certificate & private key manual management
  - [x] Raw Nginx vhost configuration live editor
- [x] **Application Runtimes & Process Supervisors**:
  - [x] **Node.js Multi-Version Engine**: 1-click install, active switch, and uninstall (v18, v20, v22, v23) via `n`
  - [x] **PM2 Process Supervisor**: Start, Stop, Restart, Status, Real-Time logs, and memory/CPU monitoring
  - [x] **Multi-PHP Engine**: PHP 8.1, 8.2, 8.3, 8.4 with isolated FPM pools, extension toggling, and `php.ini` editor
  - [x] **Docker Container Orchestration**: Container lifecycle controls, image pulling, and container status monitoring
- [x] **Database Engine & Cluster Management**:
  - [x] PostgreSQL 16 automated setup, user privileges, and schema management
  - [x] MySQL / MariaDB and MongoDB engine support
  - [x] 1-Click Database backup dump and instant restore
- [x] **File Management & Object Storage**:
  - [x] Native Pure Rust File Manager integrated inside dPanel UI with live editor, permissions, and multi-file uploader
  - [x] S3-compatible Object Storage Bucket manager
- [x] **Network Infrastructure & Protocols**:
  - [x] Pure-FTPd Virtual FTP accounts with chrooted home directories
  - [x] BIND9 Named DNS Zone and Record manager (A, AAAA, CNAME, MX, TXT, SRV, NS)
  - [x] Mail Server integration with automated DKIM/SPF record generation
  - [x] Interactive Web Terminal / PTY Console
- [x] **Security Center & Server Defense**:
  - [x] Fail2ban real-time brute force defense & IP ban/unban controls
  - [x] UFW / Iptables firewall port rules & IP access filters
  - [x] Traffic & DDoS rate-limiting engine
  - [x] Argon2id password hashing & SHA-512 token encryption
  - [x] Server Health & Threshold Alerts (CPU, Memory, Disk usage alerts)
  - [x] Visual Cron Job Scheduler with standard syntax validator

---

### Roadmap & Upcoming Features (Future Milestones)

- [ ] **Multi-Server Fleet Orchestration**: Manage 100+ VPS/dedicated nodes from a single centralized master panel.
- [ ] **Automated Cloud Backup Sync**: Scheduled offsite backup sync to AWS S3, Google Drive, Backblaze B2, and Wasabi.
- [ ] **1-Click Application & CMS Installer**: WordPress, Nextcloud, Ghost, Strapi, and Laravel instant deployment with auto-configured databases and SSL.
- [ ] **In-Memory Cache Manager**: 1-Click Redis & Memcached instance provisioning and memory limit visual tuning.
- [ ] **Web Application Firewall (WAF) Rule Engine**: ModSecurity + OWASP Core Rule Set (CRS) GUI configuration.
- [ ] **Granular Multi-User RBAC & Reseller Tiers**: Team accounts, sub-tenant permissions, and user activity audit trails.
- [ ] **Git Deployment Webhooks**: Zero-downtime auto-deployments triggered on GitHub and GitLab commits.
- [ ] **Advanced Traffic & Analytics Dashboard**: Real-time visitor logs, geographical access maps, and HTTP status code metrics.

---

## 3. Technology Stack Breakdown

| Layer | Technologies & Implementations |
| :--- | :--- |
| **Backend Core** | Rust (Edition 2021), Tokio Async Runtime, Axum 0.7, Tower, Tower-HTTP |
| **Database & ORM** | PostgreSQL 16, SQLx Async Connection Pool, Automated Embedded Migrations |
| **Frontend UI** | React 19, TypeScript, Tailwind CSS, Vite, Lucide Icons (Single Light Theme) |
| **App Runtimes** | Node.js Multi-Version (`n`), PM2 Process Supervisor, Multi-PHP (8.1 - 8.4 FPM) |
| **Web & Proxy** | Nginx High-Performance Web Server, Let's Encrypt Automated SSL (ACME / Certbot) |
| **File Management** | Native Pure Rust File Manager integrated inside Web Control Plane (Port 2083) |
| **Containers & DNS** | Docker Engine API, BIND9 Named DNS Engine, Pure-FTPd Virtual Accounts |
| **Security Suite** | Fail2ban Intrusion Defense, UFW / Iptables Port Rules, Argon2id Password Hashing |

---

## 4. Compatible Operating Systems

dPanel Enterprise is strictly validated and optimized for 64-bit Linux architectures (`x86_64`):

- **Ubuntu Linux**: 22.04 LTS (Jammy Jellyfish), 24.04 LTS (Noble Numbat)
- **Debian GNU/Linux**: 12 (Bookworm), 11 (Bullseye)
- **Alpine Linux**: 3.19+, 3.20+ (OpenRC init supported)

---

## 5. Deployment Package Layout

```text
deploy/
├── bin/
│   ├── dpanel-server   # Standalone Web Server + Embedded UI + SQL Migrations
│   └── dpaneld         # Privileged System Supervisor & IPC Daemon
├── install.sh          # Enterprise Automated 1-Click Installer (< 30s Execution)
└── README.md           # Production Deployment Guide & Documentation
```

---

## 6. Quick 1-Click Production Installation

### Step 1: Clone or Transfer the Deploy Package to Your VPS

```bash
# Clone the deployment package to your server
cd /opt
git clone https://github.com/devsecit/dPanel.git
cd dPanel/deploy
```

### Step 2: Execute the Automated Installer as Root

```bash
sudo bash install.sh
```

### Step 3: Access Your Control Panel

Upon completion, the installer displays your generated Super Admin credentials:

- **Panel URL**: `http://<YOUR_VPS_IP>:2083`
- **Default Username**: `superadmin`
- **Default Password**: *(Randomly generated and displayed upon install)*
- **Configuration File**: `/etc/dpanel/.env`

---

## 7. Required Firewall Ports

Ensure the following inbound ports are open in your cloud provider security group (AWS, DigitalOcean, Hetzner, Linode, GCP, Vultr):

| Port | Protocol | Purpose |
| :--- | :--- | :--- |
| **`2083`** | TCP | dPanel Web Control Plane, UI & REST API |
| **`888`** | TCP | phpMyAdmin 1-Click SSO Web GUI |
| **`80`** | TCP | HTTP Web Traffic / ACME SSL Challenge |
| **`443`** | TCP | HTTPS Web Traffic (Nginx SSL Reverse Proxy) |
| **`21` / `20`** | TCP | Pure-FTPd FTP Control & Passive Data Ports (30000-31000) |
| **`53`** | TCP/UDP | BIND9 DNS Nameserver |

---

## 8. Service Management & Troubleshooting

### System Service Commands

```bash
# Check status of both services
sudo systemctl status dpanel-server
sudo systemctl status dpaneld

# Restart dPanel
sudo systemctl restart dpanel-server dpaneld

# View real-time application logs
sudo journalctl -u dpanel-server -f
sudo journalctl -u dpaneld -f
```

### Resetting Super Admin Password

If you lose access to the Super Admin account, reset the password directly via PostgreSQL:

```bash
# Connect to PostgreSQL and reset superadmin password
sudo -u postgres psql -d dpanel_db -c "UPDATE users SET password_hash = '\$argon2id\$v=19\$m=19456,t=2,p=1\$dpanel\$...' WHERE username = 'superadmin';"
```

Alternatively, restart `dpanel-server` after updating `INITIAL_ADMIN_PASSWORD` in `/etc/dpanel/.env`.

---

## 9. Enterprise Security Standards

- **Zero Client-Side Hardcoded Secrets**: All JWT tokens, database connection strings, and encryption keys are injected strictly via `/etc/dpanel/.env` with strict `chmod 600` permissions.
- **Argon2id Key Derivation**: User passwords and API keys are hashed with state-of-the-art Argon2id cryptographic parameters.
- **SQL Injection Prevention**: All queries utilize parameterized type-safe queries via SQLx.

---

## 10. About DEV SEC IT

**DEV SEC IT** is a specialized cybersecurity and enterprise software engineering collective dedicated to building hardened, scalable, and developer-centric infrastructure solutions.

- **Website**: [https://devsecit.com](https://devsecit.com)
- **GitHub**: [https://github.com/devsecit](https://github.com/devsecit)
- **Community & Support**: [devsecit.com/contact](https://devsecit.com/contact)

---

### ⭐ Star the Repository
Help us reach **100 Stars** on GitHub to unlock the complete source code, developer build scripts, and plugin SDK for the entire open-source ecosystem!
