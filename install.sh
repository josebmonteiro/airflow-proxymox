#!/usr/bin/env bash
set -e

AIRFLOW_VERSION=2.9.1
AIRFLOW_HOME=/home/airflow/airflow

echo "Checking previous installation..."
if [ -f /etc/systemd/system/airflow-webserver.service ]; then
  echo "Airflow already installed. Exiting."
  exit 0
fi

echo "Updating system"
apt update

echo "Installing dependencies"
apt install -y python3 python3-venv python3-pip postgresql redis-server \
build-essential libssl-dev libffi-dev libsasl2-dev libpq-dev

echo "Creating airflow user"
useradd -m -s /bin/bash airflow || true

echo "Configuring PostgreSQL"
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'airflow') THEN
      CREATE ROLE airflow LOGIN PASSWORD 'airflow';
   END IF;
END
\$\$;

SELECT 'CREATE DATABASE airflow OWNER airflow'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'airflow')\gexec
EOF

echo "Installing Airflow"
sudo -u airflow bash <<EOF
cd ~
python3 -m venv airflow-venv
source airflow-venv/bin/activate

pip install --upgrade pip wheel setuptools
pip install apache-airflow[postgres,celery,redis]==$AIRFLOW_VERSION

mkdir -p $AIRFLOW_HOME
export AIRFLOW_HOME=$AIRFLOW_HOME

airflow db migrate

airflow users create \
 --username admin \
 --password admin \
 --firstname Admin \
 --lastname User \
 --role Admin \
 --email admin@local
EOF

echo "Configuring airflow.cfg"
sudo -u airflow bash <<EOF
source ~/airflow-venv/bin/activate
export AIRFLOW_HOME=$AIRFLOW_HOME

sed -i 's|executor = SequentialExecutor|executor = CeleryExecutor|' $AIRFLOW_HOME/airflow.cfg
sed -i 's|sql_alchemy_conn = .*|sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@localhost/airflow|' $AIRFLOW_HOME/airflow.cfg
sed -i 's|broker_url = .*|broker_url = redis://localhost:6379/0|' $AIRFLOW_HOME/airflow.cfg
sed -i 's|result_backend = .*|result_backend = db+postgresql://airflow:airflow@localhost/airflow|' $AIRFLOW_HOME/airflow.cfg
EOF

echo "Creating systemd services"

cat <<EOF >/etc/systemd/system/airflow-webserver.service
[Unit]
Description=Airflow Webserver
After=network.target

[Service]
User=airflow
Environment=AIRFLOW_HOME=/home/airflow/airflow
ExecStart=/home/airflow/airflow-venv/bin/airflow webserver --port 8080
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

