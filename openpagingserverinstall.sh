#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

check_supported_cpu_architecture() {
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64|aarch64|arm64)
            return 0
            ;;
        *)
            echo "Open Paging Server is not compatible with your CPU architecture."
            echo "Your CPU must be amd64 (x86_64) or arm64 (AArch64). Your architecture is $arch."
            echo "Ensure you are using a 64-bit CPU and a 64-bit Operating System."
            exit 1
            ;;
    esac
}

check_supported_operating_system() {
    if [ ! -f /etc/os-release ]; then
        echo "Open Paging Server requires Debian 11 or Ubuntu 20.04 or later."
        echo "You are running an unknown operating system."
        exit 1
    fi

    . /etc/os-release

    OS_NAME="${PRETTY_NAME:-${NAME:-unknown operating system}}"
    OS_ID="${ID:-}"
    OS_ID="${OS_ID,,}"
    OS_VERSION="${VERSION_ID:-0}"

    if printf '%s\n' "$OS_NAME" "$OS_ID" | grep -qi "Sangoma"; then
        echo
        echo "Open Paging Server is designed to be installed on a separate virtual machine or server instead of being installed alongside FreePBX or Asterisk. Please install a Linux box and try again."
        echo
        echo "You are running $OS_NAME"
        exit 1
    fi

    supported=0

    case "$OS_ID" in
        debian)
            if command -v dpkg >/dev/null 2>&1 && dpkg --compare-versions "$OS_VERSION" ge "11"; then
                supported=1
            fi
            ;;
        ubuntu)
            if command -v dpkg >/dev/null 2>&1 && dpkg --compare-versions "$OS_VERSION" ge "20.04"; then
                supported=1
            fi
            ;;
    esac

    if [ "$supported" -eq 0 ]; then
        echo "Open Paging Server requires Debian 11 or Ubuntu 20.04 or later."
        echo "You are running $OS_NAME"
        exit 1
    fi

    if command -v asterisk >/dev/null 2>&1 \
        || command -v fwconsole >/dev/null 2>&1 \
        || command -v amportal >/dev/null 2>&1 \
        || [ -d /etc/freepbx ] \
        || [ -d /var/www/html/admin ] \
        || [ -d /etc/asterisk ] \
        || [ -f /etc/asterisk/asterisk.conf ]; then

        echo
        echo "Open Paging Server is designed to be installed on a separate virtual machine or server instead of being installed alongside FreePBX or Asterisk. If you would like to continue, ensure that SIP and Web ports don't overlap."
        echo

        while true; do
            printf "Continue [y/n]: " > /dev/tty
            read -r answer < /dev/tty

            case "${answer,,}" in
                y|yes)
                    break
                    ;;
                n|no)
                    echo "Aborting."
                    exit 1
                    ;;
                *)
                    echo "Please enter y or n."
                    ;;
            esac
        done
    fi
}

check_supported_cpu_architecture
check_supported_operating_system

INSTALLER_ENDPOINT="${OPS_INSTALLER_ENDPOINT:-https://install.openpagingserver.org/}"
OPS_DIR="/opt/OpenPagingServer"
OPS_SERVICE="/etc/systemd/system/openpagingserver.service"
OPS_MARKER="/opt/OpenPagingServer/.openpagingserver-install"
ASSETS_DIR="/var/lib/openpagingserver/assets"
ENDPOINT_MODULES_DIR="/var/lib/openpagingserver/endpointmodules"
TRUSTED_CA_DIR="/etc/openpagingserver/trustedca"
CISCO_REPO="https://github.com/OpenPagingServer/cisco.git"
POLYCOM_REPO="https://github.com/OpenPagingServer/polycom.git"
YEALINK_REPO="https://github.com/OpenPagingServer/yealink.git"
DISCORD_WEBHOOK_REPO="https://github.com/OpenPagingServer/discordwebhook.git"
ASSETS_REPO="https://github.com/OpenPagingServer/assets.git"
ROOT_CA_URL="https://install.openpagingserver.org/rootca.crt"
TRUSTED_CA_README_URL="https://install.openpagingserver.org/trustedca-dir.md"

service_exists() {
    systemctl list-unit-files "$1" >/dev/null 2>&1
}

systemctl_try() {
    if command -v systemctl >/dev/null 2>&1 && service_exists "$1"; then
        shift
        systemctl "$@" || true
    fi
}

is_real_openpagingserver_install() {
    if [ ! -d "$OPS_DIR" ]; then
        return 1
    fi

    if [ -f "$OPS_MARKER" ] && grep -q '^PROJECT=OpenPagingServer$' "$OPS_MARKER" && grep -q '^SOURCE=https://github.com/OpenPagingServer/OpenPagingServer$' "$OPS_MARKER"; then
        return 0
    fi

    if [ ! -f "$OPS_SERVICE" ]; then
        return 1
    fi

    if ! grep -q '^Description=Open Paging Server$' "$OPS_SERVICE"; then
        return 1
    fi

    if ! grep -q '^WorkingDirectory=/opt/OpenPagingServer$' "$OPS_SERVICE"; then
        return 1
    fi

    if ! grep -q '^ExecStart=/opt/OpenPagingServer/.venv/bin/python /opt/OpenPagingServer/index.py$' "$OPS_SERVICE"; then
        return 1
    fi

    if [ ! -f "$OPS_DIR/index.py" ]; then
        return 1
    fi

    if [ ! -f "$OPS_DIR/scripts/database-initialization.py" ]; then
        return 1
    fi

    return 0
}

write_ops_marker() {
    cat > "$OPS_MARKER" <<'EOF_MARKER'
PROJECT=OpenPagingServer
SOURCE=https://github.com/OpenPagingServer/OpenPagingServer
INSTALL_PATH=/opt/OpenPagingServer
EOF_MARKER
}

installed_ops_version() {
    if [ ! -f "$OPS_DIR/pyproject.toml" ]; then
        echo ""
        return 0
    fi

    python3 - "$OPS_DIR/pyproject.toml" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
match = re.search(r'^version\s*=\s*["\']([^"\']+)["\']\s*$', text, re.MULTILINE)
print(match.group(1) if match else "")
PY
}

is_legacy_0_1_version() {
    CURRENT_VERSION="$(installed_ops_version)"

    case "$CURRENT_VERSION" in
        0.1|0.1.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_legacy_pre_0_3_version() {
    CURRENT_VERSION="$(installed_ops_version)"

    case "$CURRENT_VERSION" in
        0.1|0.1.*|0.2|0.2.*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_0_3_or_later_version() {
    CURRENT_VERSION="$(installed_ops_version)"

    if [ -z "$CURRENT_VERSION" ]; then
        return 1
    fi

    python3 - "$CURRENT_VERSION" <<'PY'
import re
import sys

version = sys.argv[1]
match = re.match(r'^(\d+)\.(\d+)\.(\d+)', version)
if not match:
    raise SystemExit(1)

major, minor, patch = map(int, match.groups())
raise SystemExit(0 if (major, minor, patch) >= (0, 3, 0) else 1)
PY
}

disable_legacy_nginx_if_needed() {
    if is_legacy_0_1_version; then
        CURRENT_VERSION="$(installed_ops_version)"

        echo
        echo "Detected Open Paging Server $CURRENT_VERSION. Stopping Nginx for the 0.1 to 0.2 upgrade."

        if command -v systemctl >/dev/null 2>&1; then
            sleep 3
            systemctl stop nginx --now || true
            sleep 3
        fi
    fi
}

fetch_releases() {
    RELEASES_JSON="$(mktemp /tmp/openpagingserver-releases.XXXXXX.json)"
    curl -fsSL \
      -H "X-OPS-Command: releases" \
      "$INSTALLER_ENDPOINT" \
      -o "$RELEASES_JSON"
}

cleanup_release_file() {
    if [ -n "${RELEASES_JSON:-}" ]; then
        rm -f "$RELEASES_JSON"
    fi
}

select_release() {
    fetch_releases

    TAG_COUNT="$(python3 - "$RELEASES_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

if data.get("status") != "ok":
    print("0")
else:
    print(len(data.get("items", [])))
PY
)"

    SELECTED_REF="main"

    if [ "$TAG_COUNT" -gt 1 ]; then
        echo
        echo "More than one OpenPagingServer tag was found."
        echo "Pick which release you want to use:"
        echo

        python3 - "$RELEASES_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for index, item in enumerate(data.get("items", []), start=1):
    print(f"{index}) {item.get('name', item.get('ref', 'unknown'))}")
PY

        while true; do
            echo
            printf "Enter release number (or 'q' to quit): " > /dev/tty
            read -r release_choice < /dev/tty

            if [ "$release_choice" = "q" ] || [ "$release_choice" = "Q" ]; then
                echo "Quitting."
                exit 0
            fi

            SELECTED_REF="$(python3 - "$RELEASES_JSON" "$release_choice" <<'PY'
import json, sys
path = sys.argv[1]
choice_raw = sys.argv[2]

try:
    choice = int(choice_raw)
except ValueError:
    print("")
    sys.exit(0)

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

items = data.get("items", [])
if choice < 1 or choice > len(items):
    print("")
    sys.exit(0)

print(items[choice - 1].get("ref", ""))
PY
)"

            if [ -n "$SELECTED_REF" ]; then
                break
            fi

            echo "Invalid release number. Please try again."
        done

    elif [ "$TAG_COUNT" -eq 1 ]; then
        SELECTED_REF="$(python3 - "$RELEASES_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

items = data.get("items", [])
print(items[0].get("ref", "main") if items else "main")
PY
)"
    else
        echo "No tags found. Using main branch."
        SELECTED_REF="main"
    fi

    cleanup_release_file
}

download_release_into_ops_dir() {
    ARCHIVE_FILE="$(mktemp /tmp/openpagingserver.XXXXXX.tar.gz)"

    curl -fsSL \
      -H "X-OPS-Command: download" \
      "$INSTALLER_ENDPOINT?ref=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SELECTED_REF")" \
      -o "$ARCHIVE_FILE"

    mkdir -p "$OPS_DIR"
    tar -xzf "$ARCHIVE_FILE" -C "$OPS_DIR" --strip-components=1
    rm -f "$ARCHIVE_FILE"
    write_ops_marker
}

latest_git_tag() {
    git ls-remote --tags --refs "$1" 'refs/tags/*' 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##' | sort -V | tail -n 1
}

latest_opsepm_asset_info() {
    repo="$1"
    tag="$2"

    repo_path="${repo#https://github.com/}"
    repo_path="${repo_path%.git}"

    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: OpenPagingServer-installer" \
      "https://api.github.com/repos/$repo_path/releases/tags/$tag" | python3 -c '
import json
import sys

raw = sys.stdin.read()
if not raw.strip():
    raise SystemExit(2)
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(2)
for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name.lower().endswith(".opsepm") and url:
        print(name)
        print(url)
        raise SystemExit(0)
raise SystemExit(1)
'
}

download_latest_opsepm_module() {
    repo="$1"
    name="$2"
    tag="$(latest_git_tag "$repo")"

    if [ -z "$tag" ]; then
        echo "No tags found for $name."
        exit 1
    fi

    asset_info="$(latest_opsepm_asset_info "$repo" "$tag" || true)"

    if [ -z "$asset_info" ]; then
        echo "No .opsepm asset found for $name tag: $tag"
        exit 1
    fi

    asset_name="$(printf '%s\n' "$asset_info" | sed -n '1p')"
    asset_url="$(printf '%s\n' "$asset_info" | sed -n '2p')"
    output="$ENDPOINT_MODULES_DIR/$asset_name"

    echo "Installing $name .opsepm from tag: $tag"
    echo "Downloading $asset_name"
    rm -f "$output"
    curl -fL "$asset_url" -o "$output"

    if [ ! -s "$output" ]; then
        echo "Downloaded .opsepm file is missing or empty: $output"
        exit 1
    fi
}

redownload_endpoint_modules() {
    mkdir -p "$ENDPOINT_MODULES_DIR"
    rm -rf "$OPS_DIR/endpoint-modules"
    find "$ENDPOINT_MODULES_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.opsepm' -delete
    download_latest_opsepm_module "$CISCO_REPO" "Cisco module"
    download_latest_opsepm_module "$POLYCOM_REPO" "Polycom module"
    download_latest_opsepm_module "$YEALINK_REPO" "Yealink module"
    download_latest_opsepm_module "$DISCORD_WEBHOOK_REPO" "Discord Webhook module"
}

redownload_assets() {
    mkdir -p /var/lib/openpagingserver

    if [ -d "$ASSETS_DIR/.git" ]; then
        git -C "$ASSETS_DIR" fetch --all --tags --prune
        default_branch="$(git -C "$ASSETS_DIR" remote show origin | awk '/HEAD branch/ {print $NF}')"
        if [ -z "$default_branch" ]; then
            default_branch="main"
        fi
        git -C "$ASSETS_DIR" checkout "$default_branch"
        git -C "$ASSETS_DIR" reset --hard "origin/$default_branch"
        git -C "$ASSETS_DIR" clean -fdx
    else
        rm -rf "$ASSETS_DIR"
        git clone "$ASSETS_REPO" "$ASSETS_DIR"
    fi
}

install_trusted_ca() {
    mkdir -p "$TRUSTED_CA_DIR"
    curl -fsSL "$ROOT_CA_URL" -o "$TRUSTED_CA_DIR/OpenPagingServerProject.crt"
    curl -fsSL "$TRUSTED_CA_README_URL" -o "$TRUSTED_CA_DIR/README.md"
}

install_python_dependencies() {
    if [ ! -x "$OPS_DIR/.venv/bin/python" ]; then
        python3 -m venv "$OPS_DIR/.venv"
    fi

    "$OPS_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel

    if [ -f "$OPS_DIR/requirements.txt" ]; then
        "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/requirements.txt"
    fi

    "$OPS_DIR/.venv/bin/pip" install \
      flask \
      flask-cors \
      pymysql \
      waitress \
      python-dotenv \
      requests \
      pillow \
      numpy \
      lxml \
      aiohttp \
      websockets \
      cryptography \
      passlib \
      argon2-cffi
}

backup_env_for_legacy_upgrade() {
    ENV_BACKUP_FILE=""

    if is_legacy_pre_0_3_version && [ -f "$OPS_DIR/.env" ]; then
        ENV_BACKUP_FILE="$(mktemp /tmp/openpagingserver-env.XXXXXX)"
        cp "$OPS_DIR/.env" "$ENV_BACKUP_FILE"
        echo "Backed up $OPS_DIR/.env"
    fi
}

restore_env_for_legacy_upgrade() {
    if [ -n "${ENV_BACKUP_FILE:-}" ] && [ -f "$ENV_BACKUP_FILE" ]; then
        cp "$ENV_BACKUP_FILE" "$OPS_DIR/.env"
        rm -f "$ENV_BACKUP_FILE"
        echo "Restored $OPS_DIR/.env"
    fi
}

backup_venv_for_legacy_upgrade() {
    VENV_BACKUP_DIR=""

    if is_legacy_pre_0_3_version && [ -d "$OPS_DIR/.venv" ]; then
        VENV_BACKUP_DIR="$(mktemp -d /tmp/openpagingserver-venv.XXXXXX)"
        cp -a "$OPS_DIR/.venv" "$VENV_BACKUP_DIR/.venv"
        echo "Backed up $OPS_DIR/.venv"
    fi
}

restore_venv_for_legacy_upgrade() {
    if [ -n "${VENV_BACKUP_DIR:-}" ] && [ -d "$VENV_BACKUP_DIR/.venv" ]; then
        rm -rf "$OPS_DIR/.venv"
        cp -a "$VENV_BACKUP_DIR/.venv" "$OPS_DIR/.venv"
        rm -rf "$VENV_BACKUP_DIR"
        echo "Restored $OPS_DIR/.venv"
    fi
}

upgrade_openpagingserver() {
    select_release

    echo
    echo "Upgrading Open Paging Server ref: $SELECTED_REF"

    disable_legacy_nginx_if_needed
    backup_env_for_legacy_upgrade
    backup_venv_for_legacy_upgrade

    if command -v systemctl >/dev/null 2>&1 && service_exists openpagingserver.service; then
        systemctl stop openpagingserver || true
    fi

    if is_legacy_pre_0_3_version; then
        echo "Detected 0.1.x or 0.2.x install. Replacing $OPS_DIR for 0.3.x upgrade."
        rm -rf "$OPS_DIR"
        mkdir -p "$OPS_DIR"
    fi

    download_release_into_ops_dir
    restore_env_for_legacy_upgrade
    restore_venv_for_legacy_upgrade
    echo "Keeping existing assets directory unchanged during upgrade."
    if is_0_3_or_later_version || ! is_legacy_pre_0_3_version; then
        echo "Refreshing all endpoint modules."
    fi
    redownload_endpoint_modules
    install_trusted_ca
    install_python_dependencies

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl restart openpagingserver || true
    fi

    echo
    echo "Open Paging Server upgrade finished."
}

uninstall_openpagingserver() {
    echo
    echo "Uninstalling Open Paging Server files and disabling the service."
    echo "The database will be kept."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop openpagingserver || true
        systemctl disable openpagingserver || true
    fi

    rm -rf "$OPS_DIR"

    echo
    echo "Open Paging Server uninstall finished."
}

existing_install_menu() {
    echo
    echo "It appears the Open Paging Server is already installed on this server. What do you want to do?"
    echo
    echo "1. Upgrade Open Paging Server"
    echo "2. Uninstall Open Paging Server"
    echo "3. Quit"
    echo
    printf "Enter choice: " > /dev/tty
    read -r existing_choice < /dev/tty

    case "$existing_choice" in
        1)
            upgrade_openpagingserver
            exit 0
            ;;
        2)
            uninstall_openpagingserver
            exit 0
            ;;
        3)
            echo "Quitting."
            exit 0
            ;;
        *)
            echo "Invalid choice."
            exit 1
            ;;
    esac
}

cat <<'EOF_WARNING'

==============================================
WARNING: This is beta software
==============================================


You are about to install an experimental project still in beta. 
Open Paging Server is currently in a very early beta state and is not yet tested or suitable for production use. 
You will MOST likely encounter bugs. If so, please make an issue on the project GitHub. 
By continuing, you authorize that this is being used in a lab or hobby environment only,
and that you will NOT use the software in its current form for life safety. If you agree, type "LAB USE ONLY".

This script is currently only designed for Debian 11 or later, or Ubuntu 20.04 or later. Python 3 will be installed if not already. MariaDB will be installed if not already, and a database will be created. 
Open Paging Server will be downloaded to /opt/OpenPagingServer, a venv will be created inside that directory, and a systemd service will be created. 
The Cisco, Polycom, Yealink, and Discord Webhook modules will also be downloaded.

NOTE: If you are updating from 0.1, nginx will be stopped.

EOF_WARNING

echo
printf ":" > /dev/tty
read -r confirm < /dev/tty

if [ "$confirm" != "LAB USE ONLY" ]; then
    echo "ABORTING"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root or with sudo."
    exit 1
fi

if is_real_openpagingserver_install; then
    existing_install_menu
fi

echo "Continuing..."

export DEBIAN_FRONTEND=noninteractive

apt update

apt install -y \
  python3 python3-venv python3-pip python3-dev \
  certbot python3-certbot \
  build-essential pkg-config \
  mariadb-server mariadb-client \
  ffmpeg fontconfig fonts-dejavu-core \
  git curl ca-certificates tar festival

systemctl enable --now mariadb

mkdir -p /opt
mkdir -p /var/lib/openpagingserver
mkdir -p "$ENDPOINT_MODULES_DIR"

RELEASES_JSON=""
trap cleanup_release_file EXIT

select_release

echo
echo "Installing OpenPagingServer ref: $SELECTED_REF"

rm -rf "$OPS_DIR"
mkdir -p "$OPS_DIR"

download_release_into_ops_dir
redownload_assets
redownload_endpoint_modules
install_trusted_ca

cd "$OPS_DIR"

python3 -m venv "$OPS_DIR/.venv"

install_python_dependencies

if [ -f "$OPS_DIR/scripts/database-initialization.py" ]; then
    "$OPS_DIR/.venv/bin/python" "$OPS_DIR/scripts/database-initialization.py"
else
    echo "Missing $OPS_DIR/scripts/database-initialization.py"
    exit 1
fi

sleep 5

cat > "$OPS_SERVICE" <<'EOF_SERVICE'
[Unit]
Description=Open Paging Server
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/OpenPagingServer
ExecStart=/opt/OpenPagingServer/.venv/bin/python /opt/OpenPagingServer/index.py
Restart=always
RestartSec=5
User=root
Group=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF_SERVICE

write_ops_marker

systemctl daemon-reload
systemctl enable openpagingserver
systemctl start openpagingserver

echo

IPS=$(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.')

lines=("Open Paging Server has been installed." "To start using Open Paging Server, access it in a web browser:")
for ip in $IPS; do
    if [ -n "$ip" ]; then
        lines+=("http://$ip")
    fi
done

max_len=0
for line in "${lines[@]}"; do
    if [ ${#line} -gt $max_len ]; then
        max_len=${#line}
    fi
done

box_width=$((max_len + 4))
term_width=$(tput cols 2>/dev/null || echo 80)
padding=$(( (term_width - box_width) / 2 ))
if [ "$padding" -lt 0 ]; then padding=0; fi

pad_str=""
if [ "$padding" -gt 0 ]; then
    pad_str=$(printf '%*s' "$padding" "")
fi

border=$(printf '═%.0s' $(seq 1 $box_width))
echo "${pad_str}╔${border}╗"

for line in "${lines[@]}"; do
    line_len=${#line}
    left_pad=$(( (max_len - line_len) / 2 ))
    right_pad=$(( max_len - line_len - left_pad ))
    
    left_space=""
    [ "$left_pad" -gt 0 ] && left_space=$(printf '%*s' "$left_pad" "")
    
    right_space=""
    [ "$right_pad" -gt 0 ] && right_space=$(printf '%*s' "$right_pad" "")
    
    echo "${pad_str}║  ${left_space}${line}${right_space}  ║"
done

echo "${pad_str}╚${border}╝"
echo
