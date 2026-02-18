# Apache Airflow Proxmox Helper Script

Instala automaticamente Apache Airflow em um container LXC no Proxmox VE.

O ambiente inclui:

- PostgreSQL metadata DB
- Redis broker
- CeleryExecutor
- Scheduler + API Server + Worker

Tempo médio de instalação: 3–6 minutos.

## Instalação

No shell do Proxmox:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/josebmonteiro/airflow-proxymox/main/airflow.sh)"
```
