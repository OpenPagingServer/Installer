#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

INSTALLER_ENDPOINT="${OPS_INSTALLER_ENDPOINT:-https://install.openpagingserver.org/}"

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

RELEASES_JSON="$(mktemp /tmp/openpagingserver-releases.XXXXXX.json)"
ARCHIVE_FILE="$(mktemp /tmp/openpagingserver.XXXXXX.tar.gz)"

cleanup_installer_tmp() {
    rm -f "$RELEASES_JSON" "$ARCHIVE_FILE"
}

trap cleanup_installer_tmp EXIT

curl -fsSL \
  -H "X-OPS-Command: releases" \
  "$INSTALLER_ENDPOINT" \
  -o "$RELEASES_JSON"

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
    echo "Pick which release you want to install:"
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
    echo "No tags found. Installing main branch."
    SELECTED_REF="main"
fi

echo
echo "Installing OpenPagingServer ref: $SELECTED_REF"

rm -rf /opt/OpenPagingServer
mkdir -p /opt/OpenPagingServer

curl -fsSL \
  -H "X-OPS-Command: download" \
  "$INSTALLER_ENDPOINT?ref=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SELECTED_REF")" \
  -o "$ARCHIVE_FILE"

tar -xzf "$ARCHIVE_FILE" -C /opt/OpenPagingServer --strip-components=1
rm -f "$ARCHIVE_FILE"

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

mkdir -p /opt/OpenPagingServer/endpoint-modules

if [ -d /opt/OpenPagingServer/endpoint-modules/cisco/.git ]; then
    git -C /opt/OpenPagingServer/endpoint-modules/cisco pull
else
    rm -rf /opt/OpenPagingServer/endpoint-modules/cisco
    git clone https://github.com/OpenPagingServer/cisco /opt/OpenPagingServer/endpoint-modules/cisco
fi

if [ -d /opt/OpenPagingServer/endpoint-modules/polycom/.git ]; then
    git -C /opt/OpenPagingServer/endpoint-modules/polycom pull
else
    rm -rf /opt/OpenPagingServer/endpoint-modules/polycom
    git clone https://github.com/OpenPagingServer/polycom /opt/OpenPagingServer/endpoint-modules/polycom
fi

cd /opt/OpenPagingServer

python3 -m venv /opt/OpenPagingServer/.venv

/opt/OpenPagingServer/.venv/bin/python -m pip install --upgrade pip setuptools wheel

if [ -f /opt/OpenPagingServer/requirements.txt ]; then
    /opt/OpenPagingServer/.venv/bin/pip install -r /opt/OpenPagingServer/requirements.txt
fi

if [ -f /opt/OpenPagingServer/endpoint-modules/cisco/requirements.txt ]; then
    /opt/OpenPagingServer/.venv/bin/pip install -r /opt/OpenPagingServer/endpoint-modules/cisco/requirements.txt
fi

if [ -f /opt/OpenPagingServer/endpoint-modules/polycom/requirements.txt ]; then
    /opt/OpenPagingServer/.venv/bin/pip install -r /opt/OpenPagingServer/endpoint-modules/polycom/requirements.txt
fi

/opt/OpenPagingServer/.venv/bin/pip install \
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

if [ -f /opt/OpenPagingServer/scripts/database-initialization.py ]; then
    /opt/OpenPagingServer/.venv/bin/python /opt/OpenPagingServer/scripts/database-initialization.py
else
    echo "Missing /opt/OpenPagingServer/scripts/database-initialization.py"
    exit 1
fi

sleep 5

cat > /etc/systemd/system/openpagingserver.service <<'EOF'
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
