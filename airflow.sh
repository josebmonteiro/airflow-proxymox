#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Apache Airflow"
var_tags="${var_tags:-automation}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-15}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

start
build_container

msg_info "Provisioning Airflow inside container..."

pct exec $CTID -- bash -c '
set -e

echo "Updating OS..."
apt update -y >/dev/null

echo "Installing dependencies..."
apt install -y python3 python3-venv python3-dev build-essential libpq-dev postgresql postgresql-contrib redis-server curl >/dev/null

echo "Starting services..."
systemctl start postgresql || service postgresql start
systemctl start redis-server || service redis-server start
sleep 5

echo "Creating database..."
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='\''airflow'\'') THEN
      CREATE ROLE airflow LOGIN PASSWORD '\''airflow'\'';
   END IF;
END
\$\$;

SELECT '\''CREATE DATABASE airflow OWNER airflow'\''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='\''airflow'\'')\gexec
EOF

mkdir -p /opt/airflow
cd /opt/airflow

echo "Creating venv..."
python3 -m venv venv
source venv/bin/activate

pip install --upgrade pip >/dev/null

AIRFLOW_VERSION=3.1.0
PYTHON_VERSION=3.11
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

echo "Installing Airflow..."
pip install "apache-airflow[celery,postgres,redis]==${AIRFLOW_VERSION}" --constraint "${CONSTRAINT_URL}" >/dev/null

export AIRFLOW_HOME=/opt/airflow
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@localhost:5432/airflow

echo "Initializing Airflow (this generates admin password)..."
airflow standalone > /opt/airflow/standalone.log 2>&1 &
sleep 35

echo "Extracting credentials..."
USER=$(grep -i "username" /opt/airflow/standalone.log | head -n1 | awk "{print \$NF}")
PASS=$(grep -i "password" /opt/airflow/standalone.log | head -n1 | awk "{print \$NF}")

echo "Username: $USER" > /root/airflow_credentials.txt
echo "Password: $PASS" >> /root/airflow_credentials.txt

pkill -f "airflow standalone" || true

echo "Starting Airflow for real..."
airflow standalone > /opt/airflow/standalone.log 2>&1 &
'

IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
CREDS=$(pct exec $CTID -- cat /root/airflow_credentials.txt)

msg_ok "Completed successfully!"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}${CREDS}${CL}"
