#!/bin/bash
set -e

# ==============================================
# KONFIGURASI UTAMA
# ==============================================
APP_NAME="nodeproxy"
MODEM_IP="192.168.11.1"
APP_PORT=5000
NGINX_PORT=80
PROXY_PORTS="7001-7999"
APP_DIR="/opt/$APP_NAME"
WEB_ROOT="/var/www/$APP_NAME"
CONFIG_DIR="/etc/$APP_NAME"

# ==============================================
# FUNGSI UTAMA
# ==============================================
function info() {
    echo -e "\e[1;36m[INFO]\e[0m $1"
}

function error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1" >&2
    exit 1
}

# ==============================================
# 1. VALIDASI INSTALASI
# ==============================================
info "Memulai instalasi NodeProxy"
if [ "$(id -u)" -ne 0 ]; then
    error "Script harus dijalankan sebagai root!"
fi

# ==============================================
# 2. INSTAL DEPENDENSI
# ==============================================
info "Menginstal dependencies sistem"
apt update -y
apt install -y \
    nginx python3-pip python3-venv nodejs npm \
    net-tools curl ufw jq qrencode \
    usb-modeswitch modemmanager netplan.io \
    build-essential git

# ==============================================
# 3. SETUP 3PROXY
# ==============================================
info "Menginstal 3proxy"
if ! command -v 3proxy &>/dev/null; then
    cd /opt
    [ -d "3proxy" ] && rm -rf 3proxy
    git clone https://github.com/z3APA3A/3proxy.git
    cd 3proxy
    make -f Makefile.Linux
    cp src/3proxy /usr/local/bin/
fi

# ==============================================
# 4. SETUP APLIKASI
# ==============================================
info "Menyiapkan direktori aplikasi"
mkdir -p $APP_DIR $WEB_ROOT $CONFIG_DIR/{config,modem} /var/log/$APP_NAME
chown -R www-data:www-data $APP_DIR $WEB_ROOT $CONFIG_DIR /var/log/$APP_NAME

# Clone repo jika belum ada
if [ ! -d "$APP_DIR/.git" ]; then
    git clone https://github.com/gofarahmad/nodeproxy.git $APP_DIR
fi

# ==============================================
# 5. SETUP BACKEND
# ==============================================
info "Menginstal backend Python"
cd $APP_DIR/backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt gunicorn requests beautifulsoup4

# Buat config
cat > $CONFIG_DIR/config/production.ini <<EOF
[app]
port = $APP_PORT
debug = false
secret_key = $(openssl rand -hex 32)

[modem]
ip = $MODEM_IP
rotate_method = disconnect
EOF

# ==============================================
# 6. MODEM CONTROLLER
# ==============================================
info "Membuat modem controller"
cat > $APP_DIR/backend/modem.py <<'EOF'
import requests
from bs4 import BeautifulSoup
import time
import logging

logging.basicConfig(filename='/var/log/nodeproxy/modem.log', level=logging.INFO)

class ModemController:
    def __init__(self, ip):
        self.base_url = f"http://{ip}"
        self.session = requests.Session()
    
    def rotate_disconnect(self):
        try:
            # Disconnect
            self.session.post(f"{self.base_url}/api/dialup/mobile-dataswitch",
                data="<request><dataswitch>0</dataswitch></request>")
            time.sleep(5)
            # Reconnect
            self.session.post(f"{self.base_url}/api/dialup/mobile-dataswitch",
                data="<request><dataswitch>1</dataswitch></request>")
            return True
        except Exception as e:
            logging.error(f"Rotate error: {str(e)}")
            return False

    def get_status(self):
        try:
            res = self.session.get(f"{self.base_url}/html/antennapointing.html")
            soup = BeautifulSoup(res.text, 'html.parser')
            return {
                'network': soup.find(id='network_mode').text,
                'operator': soup.find(id='operator').text,
                'status': soup.find(id='index_connection_status').text,
                'signal': {
                    'rssi': soup.find(id='rssi').text,
                    'rsrp': soup.find(id='signal_table_value_1').text,
                    'sinr': soup.find(id='signal_table_value_2').text,
                    'rsrq': soup.find(id='signal_table_value_3').text
                }
            }
        except Exception as e:
            logging.error(f"Status error: {str(e)}")
            return None
EOF

# ==============================================
# 7. SETUP FRONTEND
# ==============================================
info "Membangun frontend"
cd $APP_DIR/frontend
npm install
npm run build
cp -r dist/* $WEB_ROOT/

# ==============================================
# 8. KONFIGURASI NGINX
# ==============================================
info "Mengkonfigurasi Nginx"
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
    }

    location /modem {
        proxy_pass http://$MODEM_IP;
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# ==============================================
# 9. SETUP 3PROXY
# ==============================================
info "Membuat konfigurasi 3proxy"
cat > $CONFIG_DIR/3proxy.cfg <<EOF
daemon
maxconn 100
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/$APP_NAME/proxy.log
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
users $APP_NAME:CL:${APP_NAME}123
auth strong
allow * * * 80-8080
proxy -n -a -p$PROXY_PORTS
EOF

# ==============================================
# 10. SYSTEMD SERVICE
# ==============================================
info "Membuat systemd service"
cat > /etc/systemd/system/$APP_NAME.service <<EOF
[Unit]
Description=NodeProxy Service
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

# ==============================================
# 11. AKHIR INSTALASI
# ==============================================
systemctl daemon-reload
systemctl enable $APP_NAME
systemctl restart $APP_NAME
systemctl restart nginx

ufw allow $NGINX_PORT/tcp
ufw allow $PROXY_PORTS/tcp
ufw --force enable

info "INSTALASI BERHASIL!"
echo -e "\n\e[1;32mWEB UI:\e[0m http://$(hostname -I | awk '{print $1}')"
echo -e "\e[1;32mProxy Port:\e[0m $PROXY_PORTS"
echo -e "\e[1;32mCredential:\e[0m $APP_NAME/${APP_NAME}123"
echo -e "\nScan QR Code untuk akses cepat:"
qrencode -t ANSI "http://$(hostname -I | awk '{print $1}')"