#!/usr/bin/env bash

cat <<'EOF'
WARNING: This is beta software

You are about to install an experimental project still in beta. Open Paging Server is currently in a very early beta state and is not yet tested or suitable for production use. You will MOST likely encounter bugs. If so, please make an issue on the project GitHub. By continuing, you authorize that this is being used in a lab or hobby environment only, and that you will NOT use the software in it's current form for life safety. If you agree, type "LAB USE ONLY".

This script is currently only designed for Debian. Python 3 will be installed if not already. MariaDB will be installed if not already, and a database will be created. Nginx and PHP will be installed. If you already have Nginx, your current configuration will be moved to /etc/nginx-old. A future version of the install script will be able to handle this properly. Open Paging Server will be downloaded to /opt/OpenPagingServer, a venv will be created inside that directory, and a systemd service will be created. The Cisco and Polycom modules will also be downloaded.
EOF

echo
read -r -p "Type LAB USE ONLY to continue: " confirm

if [ "$confirm" != "LAB USE ONLY" ]; then
    echo "ABORTING"
    exit 1
fi

echo "Continuing..."
echo "Coming soon..."
