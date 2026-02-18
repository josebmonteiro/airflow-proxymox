#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Source: https://airflow.apache.org
# Author: Jose Monteiro
# License: MIT

APP="Apache Airflow"
var_tags="${var_tags:-etl,analytics,python}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors
start
build_container

msg_info "Provisioning Airflow inside container (this may take a few minutes)"

pct exec $CTID -- bash -c "$(wget -qLO - https://raw.githubusercontent.com/josebmonteiro/airflow-proxymox/main/install.sh)"

msg_info "Waiting for Airflow API..."
sleep 10

msg_ok "Completed successfully!"
echo -e "${CREATING}${GN}Apache Airflow has been successfully installed!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${TAB}User: admin"
echo -e "${TAB}Password: admin"
