#!/usr/bin/env bash
# One-time setup. Run in the folder with docker-compose.yml and .env:  bash setup.sh
# Creates every folder the compose file mounts and writes the config files
# (Postgres init, Prometheus, Grafana datasource, iDRAC exporter, Frigate).
# Safe to re-run: existing config files are kept and nothing is deleted.
# Optional .env lines: IDRAC_USER / IDRAC_PASS (default to UNIUSER / UNIPASS).

set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "No .env next to setup.sh"; exit 1; }
set -a; . ./.env; set +a

: "${APPDATA:?set APPDATA in .env}"
: "${SAS_2TB_1:?set SAS_2TB_1 in .env}"
: "${PUID:?set PUID in .env}"
: "${PGID:?set PGID in .env}"
: "${UNIUSER:?set UNIUSER in .env}"
: "${UNIPASS:?set UNIPASS in .env}"
: "${PROXMOX_IP:?add PROXMOX_IP to .env}"
: "${IDRAC_IP:?add IDRAC_IP to .env}"
IDRAC_USER="${IDRAC_USER:-$UNIUSER}"
IDRAC_PASS="${IDRAC_PASS:-$UNIPASS}"

# A missing mount would silently put 2TB-bound folders on the small NVMe disk.
if ! mountpoint -q "$SAS_2TB_1"; then
  echo "$SAS_2TB_1 is not a mounted drive. Mount the 2TB first."
  exit 1
fi

make_dirs() { local uid="$1" gid="$2"; shift 2; install -d -o "$uid" -g "$gid" "$@"; }

echo "== folders on APPDATA ($APPDATA)"
make_dirs "$PUID" "$PGID" "$APPDATA"
cd "$APPDATA"
make_dirs "$PUID" "$PGID" \
  npm npm/data npm/letsencrypt \
  portfolio redis \
  postgres postgres/data postgres/init \
  authentik authentik/data authentik/templates authentik/certs \
  synapse synapse/db synapse/data \
  vaultwarden \
  ntfy ntfy/cache ntfy/etc \
  searxng searxng/config searxng/valkey \
  actual \
  filebrowser filebrowser/database filebrowser/config \
  jellyfin jellyfin/config jellyfin/config/data jellyfin/config/data/metadata jellyfin/config/data/trickplay \
  navidrome \
  immich immich/postgres immich/model-cache \
  frigate diun homepage portainer uptime-kuma \
  netdata netdata/config netdata/lib netdata/cache \
  prometheus prometheus/data \
  grafana grafana/data grafana/provisioning \
  idrac-exporter
make_dirs 33 33 nextcloud
cd - >/dev/null

echo "== folders on the 2TB ($SAS_2TB_1)"
make_dirs "$PUID" "$PGID" \
  "$SAS_2TB_1/forgejo" "$SAS_2TB_1/minecraft" "$SAS_2TB_1/frigate" \
  "$SAS_2TB_1/jellyfin" "$SAS_2TB_1/jellyfin/cache" "$SAS_2TB_1/jellyfin/metadata" "$SAS_2TB_1/jellyfin/trickplay" \
  "$SAS_2TB_1/immich" "$SAS_2TB_1/immich/upload" "$SAS_2TB_1/immich/library" \
  "$SAS_2TB_1/Navidrome_Music" "$SAS_2TB_1/Wkx" "$SAS_2TB_1/Leisure"
make_dirs 33 33 "$SAS_2TB_1/nextcloud" "$SAS_2TB_1/nextcloud/data"

# Nextcloud (uid 33) needs write access to the folders it uses as external storage
if command -v setfacl >/dev/null 2>&1; then
  setfacl -m u:33:rwx,d:u:33:rwx "$SAS_2TB_1/Wkx" "$SAS_2TB_1/Leisure"
else
  echo "  note: run 'apt install -y acl', then re-run this script, so Nextcloud can write to Wkx and Leisure"
fi

write_once() {
  if [ -e "$1" ]; then
    echo "  keep   $1 (already exists)"; cat >/dev/null
  else
    cat > "$1"; chown "$PUID:$PGID" "$1"; echo "  wrote  $1"
  fi
}

echo "== config files"

# Runs only the first time Postgres starts on an empty data folder.
write_once "$APPDATA/postgres/init/10-create-dbs.sh" <<'EOF'
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'EOSQL'
CREATE DATABASE nextcloud;
CREATE DATABASE forgejo;
EOSQL
EOF

write_once "$APPDATA/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: cadvisor
    static_configs:
      - targets: ['cadvisor:8080']

  - job_name: node-vm
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: postgres
    static_configs:
      - targets: ['postgres-exporter:9187']

  - job_name: node-proxmox
    static_configs:
      - targets: ['${PROXMOX_IP}:9100']

  # iDRAC via idrac-exporter (Redfish); 'target' is filled in by the relabel rules
  - job_name: idrac
    scrape_interval: 60s
    scrape_timeout: 50s
    static_configs:
      - targets: ['${IDRAC_IP}']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: idrac-exporter:9348
EOF

write_once "$APPDATA/grafana/provisioning/datasource.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

write_once "$APPDATA/idrac-exporter/idrac.yml" <<EOF
address: 0.0.0.0
port: 9348
timeout: 30
metrics:
  system: true
  sensors: true
  power: true
  processors: true
  memory: true
  storage: true
  events: false
hosts:
  default:
    username: ${IDRAC_USER}
    password: ${IDRAC_PASS}
    # iDRAC7 only speaks old TLS key exchange
    allow_legacy_rsa_kex: true
EOF

# Frigate: reads the Pi's stream from mediamtx; nothing is kept longer than 7 days
write_once "$APPDATA/frigate/config.yml" <<'EOF'
mqtt:
  enabled: false

# CPU-only detection (no Coral/GPU). If CPU use is high, lower detect.fps.
detectors:
  cpu1:
    type: cpu
    num_threads: 3

record:
  enabled: true
  continuous:
    days: 3
  motion:
    days: 7
  alerts:
    retain:
      days: 7
      mode: motion
  detections:
    retain:
      days: 7
      mode: motion

cameras:
  cam:
    ffmpeg:
      inputs:
        - path: rtsp://mediamtx:8554/cam
          roles:
            - detect
            - record
    detect:
      enabled: true
      fps: 5
EOF

echo
echo "Done. Next: docker compose config -q"
