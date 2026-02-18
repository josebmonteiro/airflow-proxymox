#!/usr/bin/env bash

# Source: https://airflow.apache.org
# Author: Jose Monteiro
# License: MIT

CTID="$1"

if [ -z "$CTID" ]; then
  echo "Uso: ./airflow.sh <CTID>"
  exit 1
fi

echo "Iniciando Airflow no container $CTID..."

pct exec $CTID -- bash -c "
cd /opt/airflow
source venv/bin/activate
export AIRFLOW_HOME=/opt/airflow
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN='postgresql+psycopg2://airflow:airflow@localhost:5432/airflow'
airflow standalone > standalone.log 2>&1 &
sleep 20
"

IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

CREDS=$(pct exec $CTID -- cat /root/airflow_credentials.txt 2>/dev/null || echo "Credenciais não encontradas")

echo ""
echo "========================================"
echo "Apache Airflow iniciado com sucesso"
echo "URL: http://$IP:8080"
echo ""
echo "$CREDS"
echo "========================================"
