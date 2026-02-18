#!/usr/bin/env bash
set -e

echo "Checking previous installation..."
if [ -f /etc/systemd/system/airflow-webserver.service ]; then
  echo "Airflow already installed"
  exit 0
fi

echo "Installing dependencies"
apt update
apt install -y python3 python3-venv python3-pip \
postgresql redis-server build-essential libssl-dev libffi-dev libpq-dev curl

echo "Creating airflow user"
useradd -m -s /bin/bash airflow || true

echo "Creating virtualenv"
sudo -u airflow bash << 'EOF'
cd ~

python3 -m venv airflow-venv
source airflow-venv/bin/activate

pip install --upgrade pip setuptools wheel

AIRFLOW_VERSION=$(pip index versions apache-airflow | head -n 2 | tail -n 1 | awk '{print $2}')
PYTHON_VERSION=$(python -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')

CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

pip install "apache-airflow[celery,postgres,redis]==${AIRFLOW_VERSION}" --constraint "${CONSTRAINT_URL}"

export AIRFLOW_HOME=~/airflow
mkdir -p ~/airflow

airflow db migrate

airflow users create \
 --username admin \
 --password admin \
 --firstname Admin \
 --lastname User \
 --role Admin \
 --email admin@local
EOF

echo "Configuring Airflow for production executor"
sudo -u airflow bash << 'EOF'
source ~/airflow-venv/bin/activate
export AIRFLOW_HOME=~/airflow

sed -i 's|executor = SequentialExecutor|executor = CeleryExecutor|' ~/airflow/airflow.cfg
sed -i 's|sql_alchemy_conn = sqlite.*|sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@localhost/airflow|' ~/airflow/airflow.cfg
sed -i 's|broker_url = .*|broker_url = redis://localhost:6379/0|' ~/airflow/airflow.cfg
sed -i 's|result_backend = .*|result_backend = db+postgresql://airflow:airflow@localhost/airflow|' ~/airflow/airflow.cfg
EOF

echo "Configuring PostgreSQL"
sudo -u postgres psql <<EOF
CREATE USER airflow WITH PASSWORD 'airflow' || true;
CREATE DATABASE airflow OWNER airflow || true;
EOF

echo "Creating systemd services"

cat <<EOF >/etc/systemd/system/airflow-webserver.service
[Unit]
Description=Airflow Webserver
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

echo "Airflow installed successfully"
