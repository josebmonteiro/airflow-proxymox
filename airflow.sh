#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Apache Airflow"
var_cpu="2"
var_ram="4096"
var_disk="20"
var_os="debian"
var_version="13"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

start
build_container

msg_info "Installing Airflow inside container..."

pct exec $CTID -- bash -c '

set -e

echo "Installing base dependencies..."
apt update -y >/dev/null
apt install -y curl git build-essential libssl-dev libffi-dev libpq-dev postgresql redis-server >/dev/null

########################################
# INSTALL PYTHON 3.11 (CRITICAL FIX)
########################################
echo "Installing Python 3.11..."
apt install -y python3.11 python3.11-venv python3.11-dev >/dev/null

########################################
# POSTGRES
########################################
echo "Configuring PostgreSQL..."
systemctl start postgresql
sudo -u postgres psql <<EOF
CREATE ROLE airflow LOGIN PASSWORD '\''airflow'\'' || true;
CREATE DATABASE airflow OWNER airflow || true;
EOF

########################################
# AIRFLOW
########################################
mkdir -p /opt/airflow
cd /opt/airflow

python3.11 -m venv venv
source venv/bin/activate

pip install --upgrade pip setuptools wheel >/dev/null

AIRFLOW_VERSION=3.1.0
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-3.11.txt"

echo "Installing Apache Airflow..."
pip install "apache-airflow[postgres,celery,redis]==${AIRFLOW_VERSION}" --constraint "$CONSTRAINT_URL"

########################################
# CONFIG
########################################
export AIRFLOW_HOME=/opt/airflow
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@localhost:5432/airflow

########################################
# INITIALIZE
########################################
echo "Initializing Airflow..."
airflow standalone > /opt/airflow/start.log 2>&1 &
sleep 40

USER=$(grep -i "username" /opt/airflow/start.log | awk "{print \$NF}" | head -n1)
PASS=$(grep -i "password" /opt/airflow/start.log | awk "{print \$NF}" | head -n1)

echo "USER=$USER" > /root/airflow_creds
echo "PASS=$PASS" >> /root/airflow_creds

pkill -f "airflow standalone"

########################################
# SERVICE
########################################
cat <<SERVICE > /etc/systemd/system/airflow.service
[Unit]
Description=Apache Airflow
After=network.target

[Service]
User=root
Environment="AIRFLOW_HOME=/opt/airflow"
Environment="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@localhost:5432/airflow"
ExecStart=/opt/airflow/venv/bin/airflow standalone
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable airflow
systemctl start airflow
'

IP=$(pct exec $CTID -- hostname -I | awk "{print \$1}")
CREDS=$(pct exec $CTID -- cat /root/airflow_creds)

msg_ok "Installation completed!"
echo ""
echo "URL: http://${IP}:8080"
echo "$CREDS"
