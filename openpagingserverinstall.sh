#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

INSTALLER_ENDPOINT="${OPS_INSTALLER_ENDPOINT:-https://install.openpagingserver.org/}"
OPS_DIR="/opt/OpenPagingServer"
OPS_SERVICE="/etc/systemd/system/openpagingserver.service"
OPS_MARKER="/opt/OpenPagingServer/.openpagingserver-install"

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

    if [ -d "$OPS_DIR/endpoint-modules" ]; then
        return 0
    fi

    return 1
}

write_ops_marker() {
    cat > "$OPS_MARKER" <<'EOF'
PROJECT=OpenPagingServer
SOURCE=https://github.com/OpenPagingServer/OpenPagingServer
INSTALL_PATH=/opt/OpenPagingServer
EOF
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
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

for index, item in enumerate(data.get("items", []), start=1):
    print(f"{index}) {item.get('name', item.get('ref', 'unknown'))}")
PY

        echo
        printf "Enter release number: " > /dev/tty
        read -r release_choice < /dev/tty

        SELECTED_REF="$(python3 - "$RELEASES_JSON" "$release_choice" <<'PY'
import json
import sys

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

        if [ -z "$SELECTED_REF" ]; then
            echo "Invalid release number."
            exit 1
        fi
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

upgrade_openpagingserver() {
    select_release

    echo
    echo "Upgrading Open Paging Server ref: $SELECTED_REF"

    if command -v systemctl >/dev/null 2>&1 && service_exists openpagingserver.service; then
        systemctl stop openpagingserver || true
    fi

    download_release_into_ops_dir

    if [ -x "$OPS_DIR/.venv/bin/python" ]; then
        if [ -f "$OPS_DIR/requirements.txt" ]; then
            "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/requirements.txt"
        fi

        if [ -f "$OPS_DIR/endpoint-modules/cisco/requirements.txt" ]; then
            "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/endpoint-modules/cisco/requirements.txt"
        fi

        if [ -f "$OPS_DIR/endpoint-modules/polycom/requirements.txt" ]; then
            "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/endpoint-modules/polycom/requirements.txt"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl start openpagingserver || true
    fi

    echo
    echo "Open Paging Server upgrade finished."
    echo "Service status:"
    systemctl --no-pager --full status openpagingserver || true
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

    if [ -d /etc/nginx-old ]; then
        rm -rf /etc/nginx
        mv /etc/nginx-old /etc/nginx

        if command -v nginx >/dev/null 2>&1; then
            nginx -t
        elif [ -x /usr/sbin/nginx ]; then
            /usr/sbin/nginx -t
        fi

        if command -v systemctl >/dev/null 2>&1 && service_exists nginx.service; then
            systemctl reload nginx || systemctl restart nginx || true
        fi
    fi

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

cat <<'EOF'

==============================================
WARNING: This is beta software
==============================================


You are about to install an experimental project still in beta. 
Open Paging Server is currently in a very early beta state and is not yet tested or suitable for production use. 
You will MOST likely encounter bugs. If so, please make an issue on the project GitHub. 
By continuing, you authorize that this is being used in a lab or hobby environment only,
and that you will NOT use the software in its current form for life safety. If you agree, type "LAB USE ONLY".

This script is currently only designed for Debian. Python 3 will be installed if not already. MariaDB will be installed if not already, and a database will be created. 
Nginx and PHP will be installed. If you already have Nginx, your current configuration will be moved to /etc/nginx-old.
A future version of the install script will be able to handle this properly. 
Open Paging Server will be downloaded to /opt/OpenPagingServer, a venv will be created inside that directory, and a systemd service will be created. 
The Cisco and Polycom modules will also be downloaded.

EOF

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
  nginx php-fpm php-cli php-mysql php-xml php-mbstring \
  python3 python3-venv python3-pip python3-dev \
  build-essential pkg-config \
  mariadb-server mariadb-client \
  ffmpeg fontconfig fonts-dejavu-core \
  git curl ca-certificates tar

NGINX_BIN="$(command -v nginx || true)"

if [ -z "$NGINX_BIN" ] && [ -x /usr/sbin/nginx ]; then
    NGINX_BIN="/usr/sbin/nginx"
fi

if [ -z "$NGINX_BIN" ]; then
    echo "Nginx installed but nginx binary was not found."
    exit 1
fi

systemctl enable --now mariadb

mkdir -p /opt
mkdir -p /var/lib/openpagingserver

RELEASES_JSON=""
trap cleanup_release_file EXIT

select_release

echo
echo "Installing OpenPagingServer ref: $SELECTED_REF"

rm -rf "$OPS_DIR"
mkdir -p "$OPS_DIR"

download_release_into_ops_dir

if [ -d /var/lib/openpagingserver/assets/.git ]; then
    git -C /var/lib/openpagingserver/assets pull
else
    rm -rf /var/lib/openpagingserver/assets
    git clone https://github.com/OpenPagingServer/assets /var/lib/openpagingserver/assets
fi

if [ -d /etc/nginx-old ]; then
    rm -rf /etc/nginx-old
fi

if [ -d /etc/nginx ]; then
    mv /etc/nginx /etc/nginx-old
fi

git clone https://github.com/OpenPagingServer/nginx-config /etc/nginx

"$NGINX_BIN" -t

mkdir -p "$OPS_DIR/endpoint-modules"

if [ -d "$OPS_DIR/endpoint-modules/cisco/.git" ]; then
    git -C "$OPS_DIR/endpoint-modules/cisco" pull
else
    rm -rf "$OPS_DIR/endpoint-modules/cisco"
    git clone https://github.com/OpenPagingServer/cisco "$OPS_DIR/endpoint-modules/cisco"
fi

if [ -d "$OPS_DIR/endpoint-modules/polycom/.git" ]; then
    git -C "$OPS_DIR/endpoint-modules/polycom" pull
else
    rm -rf "$OPS_DIR/endpoint-modules/polycom"
    git clone https://github.com/OpenPagingServer/polycom "$OPS_DIR/endpoint-modules/polycom"
fi

cd "$OPS_DIR"

python3 -m venv "$OPS_DIR/.venv"

"$OPS_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel

if [ -f "$OPS_DIR/requirements.txt" ]; then
    "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/requirements.txt"
fi

if [ -f "$OPS_DIR/endpoint-modules/cisco/requirements.txt" ]; then
    "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/endpoint-modules/cisco/requirements.txt"
fi

if [ -f "$OPS_DIR/endpoint-modules/polycom/requirements.txt" ]; then
    "$OPS_DIR/.venv/bin/pip" install -r "$OPS_DIR/endpoint-modules/polycom/requirements.txt"
fi

"$OPS_DIR/.venv/bin/pip" install \
  flask \
  flask-cors \
  pymysql \
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

if [ -f "$OPS_DIR/scripts/database-initialization.py" ]; then
    "$OPS_DIR/.venv/bin/python" "$OPS_DIR/scripts/database-initialization.py"
else
    echo "Missing $OPS_DIR/scripts/database-initialization.py"
    exit 1
fi

sleep 5

cat > "$OPS_SERVICE" <<'EOF'
[Unit]
Description=Open Paging Server
After=network-online.target mariadb.service nginx.service
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
EOF

write_ops_marker

systemctl daemon-reload
systemctl enable nginx
systemctl start nginx
systemctl reload nginx
systemctl enable openpagingserver
systemctl start openpagingserver

echo
echo "Open Paging Server install finished."
echo "Service status:"
systemctl --no-pager --full status openpagingserver || true
