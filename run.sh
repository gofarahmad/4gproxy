#!/bin/bash
set -e

APP_NAME="nodeproxy"
APP_DIR="/opt/$APP_NAME"
WEB_ROOT="/var/www/$APP_NAME"
APP_PORT=5000
NGINX_PORT=80
CONFIG_DIR="/etc/$APP_NAME"
GIT_REPO="https://github.com/gofarahmad/nodeproxy.git"

if [ "$(id -u)" -ne 0 ]; then
  echo "Script harus dijalankan sebagai root"
  exit 1
fi

echo "[1] Install paket..."
apt-get update -y
apt-get install -y \
  git nginx python3-pip python3-venv nodejs npm \
  net-tools vnstat curl ufw iptables-persistent netplan.io

echo "[2] Install 3proxy (jika belum ada)..."
if ! command -v 3proxy &>/dev/null; then
  cd /opt
  git clone https://github.com/z3APA3A/3proxy.git
  cd 3proxy
  make -f Makefile.Linux
  cp src/3proxy /usr/local/bin/
fi

echo "[3] Setup direktori..."
mkdir -p $APP_DIR $WEB_ROOT $CONFIG_DIR/config
chown -R www-data:www-data $APP_DIR $WEB_ROOT $CONFIG_DIR

echo "[4] Clone repo..."
if [ -d "$APP_DIR/.git" ]; then
  cd $APP_DIR && git pull
else
  git clone $GIT_REPO $APP_DIR
fi

echo "[5] Setup backend..."
cd $APP_DIR/backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pip install gunicorn

cat > $CONFIG_DIR/config/production.ini <<EOF
[app]
port = $APP_PORT
debug = false
secret_key = $(openssl rand -hex 32)

[database]
path = $CONFIG_DIR/db.sqlite
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

echo "[6] Build frontend..."
cd $APP_DIR/frontend
npm install
npm run build
cp -r dist/* $WEB_ROOT/
chown -R www-data:www-data $WEB_ROOT

echo "[7] Konfigurasi nginx..."
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
}
EOF

ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

echo "[8] Enable service & firewall..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable $APP_NAME
systemctl restart $APP_NAME

ufw allow $NGINX_PORT/tcp
ufw allow 22/tcp
ufw allow 7001:8999/tcp
ufw --force enable

echo "[SELESAI] Aplikasi sudah terinstal dan berjalan."
