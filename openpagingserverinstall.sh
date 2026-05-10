#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
  git curl ca-certificates

NGINX_BIN="$(command -v nginx || true)"

if [ -z "$NGINX_BIN" ] && [ -x /usr/sbin/nginx ]; then
    NGINX_BIN="/usr/sbin/nginx"
fi

if [ -z "$NGINX_BIN" ]; then
    echo "Nginx installed but nginx binary was not found."
    exit 1
fi

systemctl stop openpagingserver || true
systemctl stop nginx || true

systemctl enable --now mariadb

mkdir -p /opt
mkdir -p /var/lib/openpagingserver

if [ -d /opt/OpenPagingServer/.git ]; then
    git -C /opt/OpenPagingServer pull
else
    rm -rf /opt/OpenPagingServer
    git clone https://github.com/OpenPagingServer/OpenPagingServer /opt/OpenPagingServer
fi

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
