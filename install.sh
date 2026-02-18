#!/usr/bin/env bash
set -e

AIRFLOW_VERSION="3.1.0"
AIRFLOW_HOME="/home/airflow/airflow"
PASS_FILE="/root/airflow_admin_password"

echo "Checking previous installation..."
if [ -f /etc/systemd/system/airflow-webserver.service ]; then
  echo "Airflow already installed"
  exit 0
fi

echo "Updating system"
apt update

echo "Installing dependencies"
apt install -y python3 python3-venv python3-pip postgresql redis-server \
build-essential libssl-dev libffi-dev libpq-dev curl

echo "Creating airflow user"
useradd -m -s /bin/bash airflow || true

echo "Creating database"
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='airflow') THEN
      CREATE ROLE airflow LOGIN PASSWORD 'airflow';
   END IF;
END
\$\$;

SELECT 'CREATE DATABASE airflow OWNER airflow'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='airflow')\gexec
EOF

echo "Installing Airflow and bootstrapping"
sudo -u airflow bash <<EOF
cd ~

python3 -m venv airflow-venv
source airflow-venv/bin/activate

pip install --upgrade pip setuptools wheel

PYTHON_VERSION=\$(python -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-\${PYTHON_VERSION}.txt"

pip install "apache-airflow[celery,postgres,redis]==${AIRFLOW_VERSION}" --constraint "\${CONSTRAINT_URL}"

export AIRFLOW_HOME=${AIRFLOW_HOME}
mkdir -p \$AIRFLOW_HOME/dags
mkdir -p \$AIRFLOW_HOME/logs
mkdir -p \$AIRFLOW_HOME/plugins

echo "Running standalone bootstrap..."
airflow standalone > /tmp/airflow_boot.log 2>&1 &
sleep 30
pkill -f "airflow standalone"
EOF

echo "Extracting admin password"
grep "Password for user 'admin'" /home/airflow/airflow/airflow-webserver.log | tail -1 | awk '{print $NF}' > $PASS_FILE || true

echo "Creating systemd services"

cat <<EOF >/etc/systemd/system/airflow-webserver.service
[Unit]
Description=Airflow API Server
After=network.target

[Service]
User=airflow
Environment=AIRFLOW_HOME=/home/airflow/airflow
ExecStart=/home/airflow/airflow-venv/bin/airflow api-server --port 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/airflow-scheduler.service
[Unit]
Description=Airflow Scheduler
After=network.target

[Service]
User=airflow
Environment=AIRFLOW_HOME=/home/airflow/airflow
ExecStart=/home/airflow/airflow-venv/bin/airflow scheduler
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/airflow-worker.service
[Unit]
Description=Airflow Worker
After=network.target

[Service]
User=airflow
Environment=AIRFLOW_HOME=/home/airflow/airflow
ExecStart=/home/airflow/airflow-venv/bin/airflow celery worker
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable airflow-webserver airflow-scheduler airflow-worker
systemctl restart airflow-webserver airflow-scheduler airflow-worker

echo "Airflow installation finished successfully"
