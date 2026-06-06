#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OPS_REPO="https://github.com/OpenPagingServer/OpenPagingServer.git"
CISCO_REPO="https://github.com/OpenPagingServer/cisco.git"
POLYCOM_REPO="https://github.com/OpenPagingServer/polycom.git"
ASSETS_REPO="https://github.com/OpenPagingServer/assets.git"
OPS_DIR="/opt/OpenPagingServer"
OPS_SERVICE="/etc/systemd/system/openpagingserver.service"
OPS_MARKER="/opt/OpenPagingServer/.openpagingserver-install"
ASSETS_DIR="/var/lib/openpagingserver/assets"
ENDPOINT_MODULES_DIR="/var/lib/openpagingserver/endpointmodules"

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

    if [ -d "$ENDPOINT_MODULES_DIR" ]; then
        return 0
    fi

    return 1
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

latest_git_tag() {
    git ls-remote --tags --refs "$1" 'refs/tags/*' 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##' | sort -V | tail -n 1
}

checkout_default_branch_repo() {
    repo="$1"
    path="$2"

    if [ -d "$path/.git" ]; then
        git -C "$path" fetch --all --tags --prune
        default_branch="$(git -C "$path" remote show origin | awk '/HEAD branch/ {print $NF}')"
        if [ -z "$default_branch" ]; then
            default_branch="main"
        fi
        git -C "$path" checkout "$default_branch"
        git -C "$path" reset --hard "origin/$default_branch"
        git -C "$path" clean -fdx -e .venv
    else
        rm -rf "$path"
        git clone "$repo" "$path"
    fi

    write_ops_marker
}

checkout_latest_tag_repo() {
    repo="$1"
    path="$2"
    name="$3"
    tag="$(latest_git_tag "$repo")"

    rm -rf "$path"

    if [ -n "$tag" ]; then
        echo "Installing $name tag: $tag"
        git clone --depth 1 --branch "$tag" "$repo" "$path"
    else
        echo "No tags found for $name. Using default branch."
        git clone "$repo" "$path"
    fi
}

redownload_assets() {
    mkdir -p /var/lib/openpagingserver
    checkout_latest_tag_repo "$ASSETS_REPO" "$ASSETS_DIR" "assets"
}

latest_opsepm_asset_url() {
    repo="$1"
    tag="$2"

    repo_path="${repo#https://github.com/}"
    repo_path="${repo_path%.git}"

    curl -fsSL "https://api.github.com/repos/$repo_path/releases/tags/$tag" | python3 -c 'import json, sys
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name.lower().endswith(".opsepm") and url:
        print(url)
        raise SystemExit(0)
raise SystemExit(1)'
}

download_latest_opsepm_module() {
    repo="$1"
    output="$2"
    name="$3"
    tag="$(latest_git_tag "$repo")"

    if [ -z "$tag" ]; then
        echo "No tags found for $name."
        exit 1
    fi

    asset_url="$(latest_opsepm_asset_url "$repo" "$tag" || true)"

    if [ -z "$asset_url" ]; then
        echo "No .opsepm asset found for $name tag: $tag"
        exit 1
    fi

    echo "Installing $name .opsepm from tag: $tag"
    rm -f "$output"
    curl -fL "$asset_url" -o "$output"
}

redownload_endpoint_modules() {
    mkdir -p "$ENDPOINT_MODULES_DIR"
    rm -rf "$OPS_DIR/endpoint-modules/cisco" "$OPS_DIR/endpoint-modules/polycom"
    rm -f "$OPS_DIR/endpoint-modules/cisco.opsepm" "$OPS_DIR/endpoint-modules/polycom.opsepm"
    rm -f "$ENDPOINT_MODULES_DIR/cisco.opsepm" "$ENDPOINT_MODULES_DIR/polycom.opsepm"
    download_latest_opsepm_module "$CISCO_REPO" "$ENDPOINT_MODULES_DIR/cisco.opsepm" "Cisco module"
    download_latest_opsepm_module "$POLYCOM_REPO" "$ENDPOINT_MODULES_DIR/polycom.opsepm" "Polycom module"
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

upgrade_openpagingserver() {
    echo
    echo "Upgrading Open Paging Server from GitHub."

    disable_legacy_nginx_if_needed

    if command -v systemctl >/dev/null 2>&1 && service_exists openpagingserver.service; then
        systemctl stop openpagingserver || true
    fi

    checkout_default_branch_repo "$OPS_REPO" "$OPS_DIR"
    redownload_assets
    redownload_endpoint_modules
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
WARNING: TEST INSTALL SCRIPT
==============================================


This is the test installer script for Open Paging Server. DO NOT RUN THIS IN A PRODUCTION ENVIRONMENT. 
The purpose of this is to test updates to the install script before they are pushed to production.

Type LAB USE ONLY to run

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

if ! grep -qi debian /etc/os-release; then
    echo "This installer is only designed for Debian."
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
  build-essential pkg-config \
  mariadb-server mariadb-client \
  ffmpeg fontconfig fonts-dejavu-core \
  git curl ca-certificates tar

systemctl enable --now mariadb

mkdir -p /opt
mkdir -p /var/lib/openpagingserver
mkdir -p "$ENDPOINT_MODULES_DIR"

echo
echo "Installing Open Paging Server from GitHub."

rm -rf "$OPS_DIR"
checkout_default_branch_repo "$OPS_REPO" "$OPS_DIR"
redownload_assets
redownload_endpoint_modules

cd "$OPS_DIR"

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
