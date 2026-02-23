#!/bin/bash
set -e

# =========================================
# Bootstrap script for Ubuntu server
# Installs required packages, Apache, MySQL, OCI CLI and Certbot
# =========================================

# --- Check if running as root ---
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# --- Function to check if a command exists ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- 1. Update system packages ---
echo "Updating system packages..."
$SUDO apt update
$SUDO apt upgrade -y

# --- 2. Install required OS packages ---
echo "Installing required packages..."
$SUDO apt install -y git apache2 mysql-server curl netfilter-persistent iptables-persistent

# --- 3. Open HTTP and HTTPS ports in iptables ---
echo "Configuring iptables..."
$SUDO iptables -I INPUT -p tcp --dport 80 -j ACCEPT
$SUDO iptables -I INPUT -p tcp --dport 443 -j ACCEPT
$SUDO netfilter-persistent save

# --- 4. Configure and start Apache ---
echo "Enabling and starting Apache..."
$SUDO systemctl enable apache2
$SUDO systemctl restart apache2

# --- 5. Configure and start MySQL ---
echo "Starting MySQL..."
$SUDO systemctl enable mysql
$SUDO systemctl start mysql

# --- 6. Set up MySQL database ---
echo "Setting up MySQL..."
DB_NAME="project_db"
DB_USER="project_user"

read -rsp "Enter MySQL password for '$DB_USER': " DB_PASS
echo

$SUDO mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" || true
$SUDO mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" || true
$SUDO mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" || true
$SUDO mysql -e "FLUSH PRIVILEGES;"

# --- 7. Install OCI CLI if not installed ---
if ! command_exists oci; then
    echo "OCI CLI not found. Installing..."
    curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci_install.sh
    chmod +x /tmp/oci_install.sh
    /tmp/oci_install.sh --accept-all-defaults --install-dir $HOME/oci
    echo 'export PATH=$PATH:$HOME/oci/bin' >> ~/.bashrc
    export PATH=$PATH:$HOME/oci/bin
else
    echo "OCI CLI is already installed."
fi

# --- 8. Install Certbot ---
echo "Installing Certbot..."
$SUDO apt install -y certbot python3-certbot-apache

read -rp "Enter your domain (e.g. example.com): " DOMAIN

echo "Requesting SSL certificate for $DOMAIN and www.$DOMAIN..."
$SUDO certbot --apache -d "$DOMAIN" -d "www.$DOMAIN"

# Verify certbot auto-renewal timer
echo "Verifying Certbot auto-renewal timer..."
$SUDO systemctl status certbot.timer --no-pager

echo ""
echo "Bootstrap completed successfully!"
echo "  - Apache: running"
echo "  - MySQL: running (db: $DB_NAME, user: $DB_USER)"
echo "  - OCI CLI: $(oci --version 2>/dev/null || echo 'installed, reload shell for PATH')"
echo "  - SSL: configured for $DOMAIN"