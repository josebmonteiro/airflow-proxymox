#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Apache Airflow (standalone) on Proxmox LXC - Auto Installer
# Based on your step-by-step (Debian 12 LXC + Postgres + Redis)
# Installs Airflow into: /opt/airflow/venv  | AIRFLOW_HOME=/opt/airflow
# Exposes: http://<CT_IP>:8080  (API Server)
# ============================================================

# ----------------------------
# Proxmox / LXC settings
# ----------------------------
CTID="${CTID:-200}"
HOSTNAME="${HOSTNAME:-airflow-base}"
TEMPLATE="${TEMPLATE:-debian-12-standard_12.12-1_amd64.tar.zst}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"          # pveam storage (templates)
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"          # CT disk storage
DISK_GB="${DISK_GB:-20}"
CORES="${CORES:-2}"
RAM_MB="${RAM_MB:-4096}"
SWAP_MB="${SWAP_MB:-1024}"
BRIDGE="${BRIDGE:-vmbr0}"
NET_CONF="${NET_CONF:-name=eth0,bridge=${BRIDGE},ip=dhcp}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"

# ----------------------------
# Airflow settings
# ----------------------------
AIRFLOW_VERSION="${AIRFLOW_VERSION:-3.1.0}"
AIRFLOW_HOME="${AIRFLOW_HOME:-/opt/airflow}"
AIRFLOW_DB_USER="${AIRFLOW_DB_USER:-airflow}"
AIRFLOW_DB_PASS="${AIRFLOW_DB_PASS:-airflow}"
AIRFLOW_DB_NAME="${AIRFLOW_DB_NAME:-airflow}"
AIRFLOW_DB_HOST="${AIRFLOW_DB_HOST:-localhost}"
AIRFLOW_DB_PORT="${AIRFLOW_DB_PORT:-5432}"

# If you want to force API bind host (extra safety):
AIRFLOW_API_HOST="${AIRFLOW_API_HOST:-0.0.0.0}"
AIRFLOW_API_PORT="${AIRFLOW_API_PORT:-8080}"

# ----------------------------
# Helpers
# ----------------------------
log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }
die() { echo -e "\n\033[1;31m[x] $*\033[0m"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# ----------------------------
# Preconditions
# ----------------------------
need_cmd pveam
need_cmd pct
need_cmd awk
need_cmd sed

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root on Proxmox."
fi

# ----------------------------
# 1) Download template (if missing)
# ----------------------------
log "Ensuring Debian template exists: $TEMPLATE"
if ! ls "/var/lib/vz/template/cache/${TEMPLATE}" >/dev/null 2>&1; then
  log "Downloading template via pveam..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
else
  log "Template already present."
fi

# ----------------------------
# 2) Create container (if missing)
# ----------------------------
if pct status "${CTID}" >/dev/null 2>&1; then
  warn "CTID ${CTID} already exists. Skipping create."
else
  log "Creating LXC container CTID=${CTID} HOSTNAME=${HOSTNAME}"
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CORES}" \
    --memory "${RAM_MB}" \
    --swap "${SWAP_MB}" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "${NET_CONF}" \
    --features nesting=1,keyctl=1 \
    --unprivileged "${UNPRIVILEGED}"
fi

# ----------------------------
# 3) Start container
# ----------------------------
log "Starting container ${CTID}"
pct start "${CTID}" || true

# Give DHCP a moment
sleep 3

# ----------------------------
# 4) Provision inside container
# ----------------------------
log "Provisioning inside container (apt + postgres + redis + airflow + systemd)"

pct exec "${CTID}" -- bash -lc "set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '[1/8] Update & install base packages'
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  python3 python3-venv python3-pip \
  build-essential libssl-dev libffi-dev libpq-dev \
  postgresql redis-server \
  procps

echo '[2/8] Ensure services started'
systemctl enable --now postgresql
systemctl enable --now redis-server

echo '[3/8] Create Postgres role+db (idempotent)'
su - postgres -c \"psql -v ON_ERROR_STOP=1 <<'SQL'
DO \\\$\\\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${AIRFLOW_DB_USER}') THEN
    CREATE ROLE ${AIRFLOW_DB_USER} LOGIN PASSWORD '${AIRFLOW_DB_PASS}';
  END IF;
END
\\\$\\\$;

SELECT 'CREATE DATABASE ${AIRFLOW_DB_NAME} OWNER ${AIRFLOW_DB_USER}'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${AIRFLOW_DB_NAME}')\\gexec
SQL\"

echo '[4/8] Create airflow unix user (idempotent)'
id airflow >/dev/null 2>&1 || useradd -m -s /bin/bash airflow

echo '[5/8] Prepare directories'
mkdir -p ${AIRFLOW_HOME}
mkdir -p ${AIRFLOW_HOME}/dags ${AIRFLOW_HOME}/logs ${AIRFLOW_HOME}/plugins
chown -R airflow:airflow ${AIRFLOW_HOME}

echo '[6/8] Create venv + install Airflow (pinned with constraints)'
if [[ ! -x '${AIRFLOW_HOME}/venv/bin/airflow' ]]; then
  python3 -m venv '${AIRFLOW_HOME}/venv'
  '${AIRFLOW_HOME}/venv/bin/pip' install --upgrade pip setuptools wheel

  PYVER=\$('${AIRFLOW_HOME}/venv/bin/python' -c 'import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")')
  CONSTRAINT_URL=\"https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-\${PYVER}.txt\"

  '${AIRFLOW_HOME}/venv/bin/pip' install \
    \"apache-airflow[postgres,redis]==${AIRFLOW_VERSION}\" \
    --constraint \"\${CONSTRAINT_URL}\"
else
  echo 'Airflow already installed in venv, skipping pip install.'
fi

echo '[7/8] Create systemd service (with PATH fix)'

cat >/etc/systemd/system/airflow.service <<'UNIT'
[Unit]
Description=Apache Airflow (standalone)
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
User=airflow
Group=airflow
Type=simple

Environment=\"AIRFLOW_HOME=${AIRFLOW_HOME}\"
Environment=\"AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${AIRFLOW_DB_USER}:${AIRFLOW_DB_PASS}@${AIRFLOW_DB_HOST}:${AIRFLOW_DB_PORT}/${AIRFLOW_DB_NAME}\"
Environment=\"AIRFLOW__API__HOST=${AIRFLOW_API_HOST}\"
Environment=\"AIRFLOW__API__PORT=${AIRFLOW_API_PORT}\"

# IMPORTANT: ensure 'airflow' is found when Airflow spawns subcommands
Environment=\"PATH=${AIRFLOW_HOME}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"

WorkingDirectory=${AIRFLOW_HOME}
ExecStart=${AIRFLOW_HOME}/venv/bin/airflow standalone

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable airflow

echo '[8/8] Start/restart Airflow'
systemctl restart airflow

echo 'Provisioning completed.'
"

# ----------------------------
# 5) Discover container IP
# ----------------------------
log "Detecting container IP"
CT_IP="$(pct exec "${CTID}" -- bash -lc "hostname -I | awk '{print \$1}'" || true)"
if [[ -z "${CT_IP}" ]]; then
  warn "Could not detect CT IP automatically. Check inside CT: hostname -I"
  CT_IP="CT_IP_NOT_FOUND"
fi

# ----------------------------
# 6) Read admin password (generated by standalone)
# ----------------------------
log "Reading admin password"
ADMIN_PASS="$(pct exec "${CTID}" -- bash -lc "cat ${AIRFLOW_HOME}/simple_auth_manager_passwords.json.generated 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin).get(\"admin\",\"\"))' || true" || true)"
if [[ -z "${ADMIN_PASS}" ]]; then
  warn "Admin password file not found yet. It can take a few seconds after first start."
  ADMIN_PASS="(check inside CT: cat ${AIRFLOW_HOME}/simple_auth_manager_passwords.json.generated)"
fi

log "Fix Airflow metadata (disable examples + reset serialized DAGs)"

pct exec "${CTID}" -- bash -lc "
set -e

cd ${AIRFLOW_HOME}

# Disable example DAGs
if grep -q 'load_examples = True' airflow.cfg; then
  sed -i 's/load_examples = True/load_examples = False/g' airflow.cfg
fi

# Stop airflow
systemctl stop airflow

# Clean serialized DAGs (CORRETO PARA POSTGRES)
export AIRFLOW_HOME=${AIRFLOW_HOME}
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://${AIRFLOW_DB_USER}:${AIRFLOW_DB_PASS}@${AIRFLOW_DB_HOST}:${AIRFLOW_DB_PORT}/${AIRFLOW_DB_NAME}

${AIRFLOW_HOME}/venv/bin/airflow db reset -y

# remove exemplos
rm -rf ${AIRFLOW_HOME}/dags/*
rm -rf ${AIRFLOW_HOME}/logs/*

# start again
systemctl start airflow
"

# ----------------------------
# 7) Output access info
# ----------------------------
echo ""
echo "============================================================"
echo "✅ Airflow instalado e serviço systemd ativo"
echo ""
echo "CTID:      ${CTID}"
echo "Hostname:  ${HOSTNAME}"
echo "IP:        ${CT_IP}"
echo ""
echo "URL:       http://${CT_IP}:${AIRFLOW_API_PORT}/"
echo "User:      admin"
echo "Password:  ${ADMIN_PASS}"
echo ""
echo "Logs:      pct exec ${CTID} -- journalctl -u airflow -f"
echo "Status:    pct exec ${CTID} -- systemctl status airflow"
echo "============================================================"
echo ""

# Extra hint for ERR_CONNECTION_REFUSED
warn "Se der ERR_CONNECTION_REFUSED:"
warn "1) Confirme que o CT tem IP e você pinga: ping ${CT_IP}"
warn "2) Verifique se o Proxmox Firewall está bloqueando a porta 8080 (Datacenter/Node/CT -> Firewall)"
warn "3) Confirme dentro do CT: ss -lntp | grep :${AIRFLOW_API_PORT}"
