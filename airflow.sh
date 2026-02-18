#!/usr/bin/env bash

# Source: https://airflow.apache.org
# Author: Jose Monteiro
# License: MIT

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

msg_info "Installing Airflow inside container..."

pct exec $CTID -- bash -c "$(wget -qLO - https://raw.githubusercontent.com/josebmonteiro/airflow-proxymox/main/install.sh)"

IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

CREDS=$(pct exec $CTID -- cat /root/airflow_credentials.txt 2>/dev/null || echo "Credentials not generated")

msg_ok "Completed successfully!"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}${CREDS}${CL}"
