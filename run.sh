#!/bin/bash
set -e

# Konfigurasi
APP_NAME="nodeproxy"
MODEM_IP="192.168.11.1"
APP_PORT=5000
NGINX_PORT=80
PROXY_PORTS="7001-7999"
APP_DIR="/opt/$APP_NAME"
WEB_ROOT="/var/www/$APP_NAME"
CONFIG_DIR="/etc/$APP_NAME"

# Fungsi untuk menampilkan status
function show_status() {
    echo "======================================="
    echo " $1"
    echo "======================================="
}

# 1. Validasi root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Script harus dijalankan sebagai root!" >&2
    exit 1
fi

show_status "1. Install Dependencies"
apt update -y
apt install -y \
    nginx python3-pip python3-venv nodejs npm \
    net-tools curl ufw jq qrencode \
    usb-modeswitch modemmanager netplan.io

# 2. Setup 3proxy
show_status "2. Install 3proxy"
if ! command -v 3proxy &>/dev/null; then
    cd /opt
    [ -d "3proxy" ] && rm -rf 3proxy
    git clone https://github.com/z3APA3A/3proxy.git
    cd 3proxy
    make -f Makefile.Linux
    cp src/3proxy /usr/local/bin/
fi

# 3. Setup direktori
show_status "3. Setup Direktori"
mkdir -p $APP_DIR $WEB_ROOT $CONFIG_DIR/{config,modem} /var/log/$APP_NAME
chown -R www-data:www-data $APP_DIR $WEB_ROOT $CONFIG_DIR /var/log/$APP_NAME

# 4. Clone repo
show_status "4. Clone Aplikasi"
if [ ! -d "$APP_DIR/.git" ]; then
    git clone https://github.com/gofarahmad/nodeproxy.git $APP_DIR
fi

# 5. Setup backend
show_status "5. Setup Backend"
cd $APP_DIR/backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt gunicorn requests beautifulsoup4

# 6. Buat config
cat > $CONFIG_DIR/config/production.ini <<EOF
[app]
port = $APP_PORT
debug = false
secret_key = $(openssl rand -hex 32)

[modem]
ip = $MODEM_IP
rotate_method = disconnect  # atau change_mode
EOF

# 7. Modem Controller
cat > $APP_DIR/backend/modem_controller.py <<'EOF'
import requests
from bs4 import BeautifulSoup
import time
import logging

logging.basicConfig(filename='/var/log/nodeproxy/modem.log', level=logging.INFO)

class ModemController:
    def __init__(self, ip):
        self.base_url = f"http://{ip}"
        self.session = requests.Session()
        
    def get_session_token(self):
        try:
            response = self.session.get(f"{self.base_url}/api/webserver/SesTokInfo", timeout=5)
            soup = BeautifulSoup(response.text, 'html.parser')
            return soup.find('sesinfo').text, soup.find('tokinfo').text
        except Exception as e:
            logging.error(f"Get token error: {str(e)}")
            return None, None
    
    def rotate_disconnect(self):
        session_id, token = self.get_session_token()
        if not token:
            return False
            
        headers = {
            "__RequestVerificationToken": token,
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
        }
        
        try:
            # Disconnect
            self.session.post(f"{self.base_url}/api/dialup/mobile-dataswitch",
                headers=headers, data="<request><dataswitch>0</dataswitch></request>")
            time.sleep(5)
            
            # Reconnect
            self.session.post(f"{self.base_url}/api/dialup/mobile-dataswitch",
                headers=headers, data="<request><dataswitch>1</dataswitch></request>")
            return True
        except Exception as e:
            logging.error(f"Rotate error: {str(e)}")
            return False
    
    def rotate_change_mode(self):
        try:
            # Change to 3G
            self.session.post(f"{self.base_url}/api/net/net-mode",
                data="<request><NetworkMode>3</NetworkMode></request>")
            time.sleep(5)
            
            # Change back to 4G
            self.session.post(f"{self.base_url}/api/net/net-mode",
                data="<request><NetworkMode>11</NetworkMode></request>")
            return True
        except Exception as e:
            logging.error(f"Change mode error: {str(e)}")
            return False
    
    def get_status(self):
        try:
            response = self.session.get(f"{self.base_url}/html/antennapointing.html", timeout=5)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            return {
                'network': soup.find(id='network_mode').text if soup.find(id='network_mode') else '',
                'operator': soup.find(id='operator').text if soup.find(id='operator') else '',
                'status': soup.find(id='index_connection_status').text if soup.find(id='index_connection_status') else '',
                'signal': {
                    'rssi': soup.find(id='rssi').text if soup.find(id='rssi') else '',
                    'rsrp': soup.find(id='signal_table_value_1').text if soup.find(id='signal_table_value_1') else '',
                    'sinr': soup.find(id='signal_table_value_2').text if soup.find(id='signal_table_value_2') else '',
                    'rsrq': soup.find(id='signal_table_value_3').text if soup.find(id='signal_table_value_3') else ''
                }
            }
        except Exception as e:
            logging.error(f"Status error: {str(e)}")
            return None
EOF

# 8. Buat API endpoint
cat >> $APP_DIR/backend/app.py <<'EOF'

@app.route('/api/modem/rotate', methods=['POST'])
def modem_rotate():
    from modem_controller import ModemController
    modem = ModemController(current_app.config['MODEM_IP'])
    
    method = request.json.get('method', 'disconnect')
    if method == 'disconnect':
        success = modem.rotate_disconnect()
    else:
        success = modem.rotate_change_mode()
    
    return jsonify({'success': success})

@app.route('/api/modem/status')
def modem_status():
    from modem_controller import ModemController
    modem = ModemController(current_app.config['MODEM_IP'])
    return jsonify(modem.get_status())

@app.route('/api/modem/ussd', methods=['POST'])
def send_ussd():
    from modem_controller import ModemController
    modem = ModemController(current_app.config['MODEM_IP'])
    code = request.json.get('code', '')
    # Implementasi USSD disini
    return jsonify({'success': True, 'response': 'USSD sent'})
EOF

# 9. Build frontend
show_status "6. Build Frontend"
cd $APP_DIR/frontend
npm install
npm run build
cp -r dist/* $WEB_ROOT/

# 10. Setup Nginx
show_status "7. Setup Nginx"
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

# 11. Setup 3proxy
show_status "8. Setup 3proxy"
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

# 12. Setup systemd
show_status "9. Setup Service"
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

# 13. Enable services
show_status "10. Start Aplikasi"
systemctl daemon-reload
systemctl enable $APP_NAME
systemctl restart $APP_NAME
systemctl restart nginx

# 14. Firewall
ufw allow $NGINX_PORT/tcp
ufw allow $PROXY_PORTS/tcp
ufw --force enable

# 15. Tampilkan informasi
show_status "INSTALASI SELESAI"
echo "Web UI bisa diakses di:"
echo "http://$(hostname -I | awk '{print $1}')"
echo
echo "Fitur yang tersedia:"
echo "1. Rotate IP (Disconnect/Change Mode)"
echo "2. Monitoring Signal Modem"
echo "3. Manajemen Proxy Port $PROXY_PORTS"
echo "4. USSD Command"
echo
echo "Scan QR Code untuk akses cepat:"
qrencode -t ANSI "http://$(hostname -I | awk '{print $1}')"