#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

AIRFLOW_VERSION="3.1.0"
PYTHON_VERSION="3.11"
AIRFLOW_HOME="/opt/airflow"
ADMIN_FILE="/root/airflow_credentials.txt"

echo "Atualizando sistema..."
apt update -y

echo "Instalando dependências..."
apt install -y \
  python${PYTHON_VERSION} \
  python${PYTHON_VERSION}-venv \
  python${PYTHON_VERSION}-dev \
  build-essential \
  libpq-dev \
  postgresql \
  postgresql-contrib \
  redis-server \
  curl \
  git

echo "Iniciando serviços..."
systemctl enable postgresql || true
systemctl start postgresql || service postgresql start || true

systemctl enable redis-server || true
systemctl start redis-server || service redis-server start || true

sleep 5

echo "Criando usuário e banco no PostgreSQL..."
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

echo "Criando diretório do Airflow..."
mkdir -p $AIRFLOW_HOME
cd $AIRFLOW_HOME

echo "Criando ambiente virtual..."
python${PYTHON_VERSION} -m venv venv
source venv/bin/activate

pip install --upgrade pip setuptools wheel

CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

echo "Instalando Airflow ${AIRFLOW_VERSION}..."
pip install "apache-airflow[celery,postgres,redis]==${AIRFLOW_VERSION}" --constraint "${CONSTRAINT_URL}"

export AIRFLOW_HOME=$AIRFLOW_HOME
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="postgresql+psycopg2://airflow:airflow@localhost:5432/airflow"

echo "Inicializando via standalone (isso cria usuário e senha automaticamente)..."

$AIRFLOW_HOME/venv/bin/airflow standalone > standalone.log 2>&1 &

sleep 30

echo "Capturando credenciais..."

USER_LINE=$(grep -i "username" standalone.log | head -n1 || true)
PASS_LINE=$(grep -i "password" standalone.log | head -n1 || true)

echo "$USER_LINE" > $ADMIN_FILE
echo "$PASS_LINE" >> $ADMIN_FILE

pkill -f "airflow standalone" || true

echo "Instalação concluída."
