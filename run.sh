#!/bin/bash
set -e

APP_NAME="nodeproxy"
APP_DIR="/opt/$APP_NAME"
WEB_ROOT="/var/www/$APP_NAME"
APP_PORT=5000
NGINX_PORT=80
CONFIG_DIR="/etc/$APP_NAME"
GIT_REPO="https://github.com/gofarahmad/nodeproxy.git"
MODEM_IP="192.168.11.1"
MODEM_API="http://$MODEM_IP/api"
PROXY_PORTS="7001-7999"

if [ "$(id -u)" -ne 0 ]; then
  echo "Script ini harus dijalankan sebagai root."
  exit 1
fi

echo "[1] Install dependensi minimal yang dibutuhkan..."
apt update -y
apt install -y \
  nginx python3-pip python3-venv nodejs npm \
  net-tools vnstat curl ufw iptables-persistent \
  netplan.io network-manager usb-modeswitch modemmanager \
  iputils-ping iproute2 jq

echo "[2] Install 3proxy jika belum ada..."
if ! command -v 3proxy &>/dev/null; then
  cd /opt
  git clone https://github.com/z3APA3A/3proxy.git
  cd 3proxy
  make -f Makefile.Linux
  cp src/3proxy /usr/local/bin/
fi

echo "[3] Setup direktori dan permission..."
mkdir -p $APP_DIR $WEB_ROOT $CONFIG_DIR/config
chown -R www-data:www-data $APP_DIR $WEB_ROOT $CONFIG_DIR

echo "[4] Clone atau update repo nodeproxy..."
if [ -d "$APP_DIR/.git" ]; then
  cd $APP_DIR && git pull
else
  git clone $GIT_REPO $APP_DIR
fi

echo "[5] Setup backend Python..."
cd $APP_DIR/backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt gunicorn

cat > $CONFIG_DIR/config/production.ini <<EOF
[app]
port = $APP_PORT
debug = false
secret_key = $(openssl rand -hex 32)

[database]
path = $CONFIG_DIR/db.sqlite

[modem]
ip = $MODEM_IP
api_url = $MODEM_API
rotate_interval = 300
EOF

cat > /etc/systemd/system/$APP_NAME.service <<EOF
[Unit]
Description=NodeProxy Backend
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP_DIR/backend
Environment="PATH=$APP_DIR/backend/venv/bin"
ExecStart=$APP_DIR/backend/venv/bin/gunicorn -w 4 -b 127.0.0.1:$APP_PORT app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "[6] Build frontend React..."
cd $APP_DIR/frontend
npm install
npm run build
cp -r dist/* $WEB_ROOT/
chown -R www-data:www-data $WEB_ROOT

echo "[7] Konfigurasi NGINX..."
cat > /etc/nginx/sites-available/$APP_NAME <<EOF
server {
    listen $NGINX_PORT;
    server_name _;

    root $WEB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /static {
        alias $APP_DIR/backend/static;
    }

    location /modem-api {
        proxy_pass http://$MODEM_IP;
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

echo "[8] Setup modem control..."
cat > $APP_DIR/backend/modem.py <<EOF
import requests
from bs4 import BeautifulSoup
import time
import logging

logging.basicConfig(filename='/var/log/$APP_NAME/modem.log', level=logging.INFO)

class ModemController:
    def __init__(self, ip='$MODEM_IP'):
        self.base_url = f"http://{ip}"
        self.session = requests.Session()
        
    def get_session_token(self):
        try:
            response = self.session.get(f"{self.base_url}/api/webserver/SesTokInfo")
            if response.status_code == 200:
                soup = BeautifulSoup(response.text, 'xml')
                return soup.SesInfo.text, soup.TokInfo.text
            return None, None
        except Exception as e:
            logging.error(f"Session token error: {str(e)}")
            return None, None
    
    def rotate_ip(self):
        session_id, token = self.get_session_token()
        if not session_id or not token:
            return False
        
        headers = {
            "__RequestVerificationToken": token,
            "Cookie": f"SessionID={session_id}",
            "Content-Type": "application/xml"
        }
        
        # Disconnect
        try:
            response = self.session.post(
                f"{self.base_url}/api/dialup/mobile-dataswitch",
                headers=headers,
                data="<request><dataswitch>0</dataswitch></request>"
            )
            time.sleep(5)
            
            # Reconnect
            response = self.session.post(
                f"{self.base_url}/api/dialup/mobile-dataswitch",
                headers=headers,
                data="<request><dataswitch>1</dataswitch></request>"
            )
            logging.info("IP rotation completed")
            return True
        except Exception as e:
            logging.error(f"Rotation failed: {str(e)}")
            return False
    
    def get_status(self):
        try:
            response = self.session.get(f"{self.base_url}/html/antennapointing.html")
            if response.status_code == 200:
                return response.text
            return None
        except Exception as e:
            logging.error(f"Status check failed: {str(e)}")
            return None
EOF

echo "[9] Setup 3proxy configuration..."
cat > $CONFIG_DIR/3proxy.cfg <<EOF
daemon
maxconn 200
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/$APP_NAME/proxy.log
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
users $APP_NAME:CL:${APP_NAME}123
auth strong
allow * * * 80-8080
proxy -n -a -p$PROXY_PORTS
EOF

echo "[10] Setup auto-rotation service..."
cat > /etc/systemd/system/modem-rotate.service <<EOF
[Unit]
Description=Modem IP Rotation Service
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=$APP_DIR/backend
Environment="PATH=$APP_DIR/backend/venv/bin"
ExecStart=$APP_DIR/backend/venv/bin/python -c "from modem import ModemController; m = ModemController(); m.rotate_ip()"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "[11] Setup rotation timer..."
cat > /etc/systemd/system/modem-rotate.timer <<EOF
[Unit]
Description=Timer for Modem IP Rotation

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

echo "[12] Restart semua service..."
nginx -t
systemctl daemon-reload
systemctl enable $APP_NAME modem-rotate.timer
systemctl restart $APP_NAME
systemctl restart nginx
systemctl start modem-rotate.timer

echo "[13] Atur firewall (UFW)..."
ufw allow $NGINX_PORT/tcp
ufw allow 22/tcp
ufw allow ${PROXY_PORTS}/tcp
ufw --force enable

echo "[14] Konfigurasi netplan hybrid..."
NETPLAN_FILE="/etc/netplan/99-nodeproxy.yaml"

cat > $NETPLAN_FILE <<EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  modems:
    wwan0:
      dhcp4: true
      optional: true
EOF

netplan apply

echo "======================================="
echo "Instalasi NodeProxy selesai!"
echo "Modem IP: $MODEM_IP"
echo "Akses Web: http://$(hostname -I | awk '{print $1}')"
echo "Port Proxy: $PROXY_PORTS"
echo "Auto-rotate: Setiap 5 menit"
echo "Logs: /var/log/$APP_NAME/"
echo "======================================="