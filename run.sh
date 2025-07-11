#!/bin/sh
set -e

# ==============================================
# KONFIGURASI (SESUAIKAN DENGAN KEBUTUHAN ANDA)
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
# FUNGSI BANTU (COMPATIBLE DENGAN SH)
# ==============================================
echo_info() {
    echo "======================================="
    echo "[INFO] $1"
    echo "======================================="
}

echo_error() {
    echo "=======================================" >&2
    echo "[ERROR] $1" >&2
    echo "=======================================" >&2
    exit 1
}

# ==============================================
# 1. VALIDASI ROOT
# ==============================================
if [ "$(id -u)" -ne 0 ]; then
    echo_error "Script harus dijalankan sebagai root!"
fi

# ==============================================
# 2. INSTAL DEPENDENSI
# ==============================================
echo_info "1. Install Dependencies"
apt update -y
apt install -y \
    nginx python3-pip python3-venv nodejs npm \
    net-tools curl ufw jq qrencode \
    usb-modeswitch modemmanager netplan.io \
    build-essential git

# ==============================================
# 3. SETUP 3PROXY
# ==============================================
echo_info "2. Install 3proxy"
if ! command -v 3proxy >/dev/null 2>&1; then
    cd /opt
    rm -rf 3proxy 2>/dev/null || true
    git clone https://github.com/z3APA3A/3proxy.git
    cd 3proxy
    make -f Makefile.Linux
    cp src/3proxy /usr/local/bin/
fi

# ==============================================
# 4. SETUP DIREKTORI
# ==============================================
echo_info "3. Setup Direktori"
mkdir -p "$APP_DIR" "$WEB_ROOT" "$CONFIG_DIR"/config /var/log/"$APP_NAME"
chown -R www-data:www-data "$APP_DIR" "$WEB_ROOT" "$CONFIG_DIR" /var/log/"$APP_NAME"

# ==============================================
# 5. CLONE REPOSITORY
# ==============================================
echo_info "4. Clone Aplikasi"
if [ ! -d "$APP_DIR/.git" ]; then
    git clone https://github.com/gofarahmad/nodeproxy.git "$APP_DIR"
fi

# ==============================================
# 6. SETUP BACKEND PYTHON
# ==============================================
echo_info "5. Setup Backend"
cd "$APP_DIR"/backend
python3 -m venv venv
./venv/bin/pip install -r requirements.txt gunicorn

# ==============================================
# 7. BUAT CONFIGURASI
# ==============================================
echo_info "6. Buat Config"
cat > "$CONFIG_DIR"/config/production.ini <<EOF
[app]
port = $APP_PORT
debug = false
secret_key = $(openssl rand -hex 32)

[modem]
ip = $MODEM_IP
rotate_interval = 300
EOF

# ==============================================
# 8. SETUP SYSTEMD SERVICE
# ==============================================
echo_info "7. Buat Service"
cat > /etc/systemd/system/"$APP_NAME".service <<EOF
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
# 9. BUILD FRONTEND
# ==============================================
echo_info "8. Build Frontend"
cd "$APP_DIR"/frontend
npm install
npm run build
cp -r dist/* "$WEB_ROOT"/

# ==============================================
# 10. KONFIGURASI NGINX
# ==============================================
echo_info "9. Setup Nginx"
cat > /etc/nginx/sites-available/"$APP_NAME" <<EOF
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
}
EOF

ln -sf /etc/nginx/sites-available/"$APP_NAME" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# ==============================================
# 11. SETUP 3PROXY.CFG
# ==============================================
echo_info "10. Setup 3proxy"
cat > "$CONFIG_DIR"/3proxy.cfg <<EOF
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
# 12. AKHIR INSTALASI
# ==============================================
echo_info "11. Starting Services"
systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl restart "$APP_NAME"
systemctl restart nginx

ufw allow "$NGINX_PORT"/tcp
ufw allow "$PROXY_PORTS"/tcp
ufw --force enable

echo_info "INSTALASI BERHASIL"
echo "Akses Web UI: http://$(hostname -I | cut -d' ' -f1)"
echo "Port Proxy: $PROXY_PORTS"
echo "Username: $APP_NAME"
echo "Password: ${APP_NAME}123"
echo "Scan QR Code:"
qrencode -t ANSI "http://$(hostname -I | cut -d' ' -f1)"