#!/usr/bin/env bash

# Source: https://airflow.apache.org
# Author: Jose Monteiro
# License: MIT

echo "Detectando container do Airflow..."

# tenta encontrar pelo hostname airflow
CTID=$(pct list | grep airflow | awk '{print $1}')

# se não encontrou, pega o último container criado
if [ -z "$CTID" ]; then
  CTID=$(pct list | awk 'NR>1 {print $1}' | tail -n1)
fi

if [ -z "$CTID" ]; then
  echo "Nenhum container encontrado."
  exit 1
fi

echo "Usando container ID: $CTID"

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