#!/bin/bash
set -euo pipefail

# ============================================================
# bootstrap.sh — Ubuntu Server Provisioning Script
#
# Sets up a production-ready environment with:
#   - Apache2  (web server)
#   - MySQL    (database)
#   - Certbot  (SSL via Let's Encrypt)
#   - OCI CLI  (Oracle Cloud Infrastructure)
#   - pipx     (isolated CLI tool installer)
#   - Poetry   (Python dependency & venv manager)
#
# Tested on: Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
# Usage:     chmod +x bootstrap.sh && ./bootstrap.sh
# ============================================================

# ---- Helpers -----------------------------------------------

# Detect whether sudo is needed
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Print a section header for readability
section() {
    echo ""
    echo "==> $1"
}

# Check whether a CLI tool is already on PATH
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Load environment variables from .env if present
if [ -f .env ]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
    echo "Loaded configuration from .env"
fi

# ---- 1. System update ----------------------------------------
section "Updating system packages"
$SUDO apt update -q
$SUDO apt upgrade -y -q

# ---- 2. Core OS packages ------------------------------------
section "Installing required packages"
$SUDO apt install -y -q \
    git \
    curl \
    apache2 \
    mysql-server \
    python3 \
    python3-pip \
    python3-venv \
    pipx \
    netfilter-persistent \
    iptables-persistent

# Ensure pipx-managed binaries are on PATH for this session
pipx ensurepath --force
export PATH="$PATH:$HOME/.local/bin"

# ---- 3. Firewall — open HTTP and HTTPS ----------------------
section "Configuring iptables (ports 80 and 443)"
$SUDO iptables -I INPUT -p tcp --dport 80 -j ACCEPT
$SUDO iptables -I INPUT -p tcp --dport 443 -j ACCEPT
$SUDO netfilter-persistent save

# ---- 4. Apache ----------------------------------------------
section "Enabling and starting Apache"
$SUDO systemctl enable apache2
$SUDO systemctl restart apache2

# ---- 5. MySQL -----------------------------------------------
section "Starting MySQL"
$SUDO systemctl enable mysql
$SUDO systemctl start mysql

# Set up project database and user
section "Configuring MySQL database"
DB_NAME="${DB_NAME:-project_db}"
DB_USER="${DB_USER:-project_user}"

if [ -z "${DB_PASS:-}" ]; then
    read -rsp "Enter MySQL password for user '$DB_USER': " DB_PASS
    echo
fi

$SUDO mysql <<-SQL
    CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;
SQL

echo "Database '${DB_NAME}' and user '${DB_USER}' configured."

# ---- 6. pipx + Poetry ---------------------------------------
section "Installing Poetry via pipx"

# pipx installs each CLI tool in its own isolated venv,
# keeping them independent from the project and from each other.
if ! command_exists poetry; then
    pipx install poetry
    echo "Poetry installed via pipx."
else
    echo "Poetry already installed: $(poetry --version)"
fi

# Configure Poetry to create the virtualenv inside the project directory (.venv/)
# This makes the environment explicit and easy to locate.
poetry config virtualenvs.in-project true

section "Installing project dependencies with Poetry"
if [ -f "pyproject.toml" ]; then
    # --no-interaction: non-interactive mode, safe for automated runs
    # --no-ansi:        clean output without color codes in logs
    poetry install --no-interaction --no-ansi
    echo "Project dependencies installed. Virtualenv: $(poetry env info --path)"
else
    echo "No pyproject.toml found — skipping poetry install."
    echo "Run 'poetry init' to initialise the project, then 'poetry install'."
fi

# ---- 7. OCI CLI ---------------------------------------------
section "Checking OCI CLI"
if ! command_exists oci; then
    echo "OCI CLI not found. Installing..."
    curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh \
        -o /tmp/oci_install.sh
    chmod +x /tmp/oci_install.sh
    /tmp/oci_install.sh --accept-all-defaults --install-dir "$HOME/oci"

    # Persist PATH update
    echo 'export PATH=$PATH:$HOME/oci/bin' >> ~/.bashrc
    export PATH="$PATH:$HOME/oci/bin"
    echo "OCI CLI installed. Run 'source ~/.bashrc' to refresh your shell."
else
    echo "OCI CLI already installed: $(oci --version)"
fi

# ---- 8. SSL — Certbot ---------------------------------------
section "Installing Certbot"
$SUDO apt install -y -q certbot python3-certbot-apache

DOMAIN="${DOMAIN:-}"
if [ -z "$DOMAIN" ]; then
    read -rp "Enter your domain (e.g. example.com): " DOMAIN
fi

echo "Requesting SSL certificate for ${DOMAIN} and www.${DOMAIN}..."
$SUDO certbot --apache -d "$DOMAIN" -d "www.${DOMAIN}"

# Confirm auto-renewal timer is active
echo "Verifying Certbot auto-renewal timer..."
$SUDO systemctl status certbot.timer --no-pager

# ---- Done ---------------------------------------------------
echo ""
echo "============================================================"
echo " Bootstrap completed successfully!"
echo "============================================================"
echo "  Apache   : running"
echo "  MySQL    : running  (db: ${DB_NAME}, user: ${DB_USER})"
echo "  pipx     : $(pipx --version)"
echo "  Poetry   : $(poetry --version)"
echo "  OCI CLI  : $(oci --version 2>/dev/null || echo 'installed — reload shell for PATH')"
echo "  SSL      : configured for ${DOMAIN}"
echo ""
echo "  Activate project venv:  source .venv/bin/activate"
echo "  Or run via Poetry:      poetry run <command>"
echo "  Add a dependency:       poetry add <package>"
echo "  Add a dev dependency:   poetry add --group dev <package>"
echo "============================================================"