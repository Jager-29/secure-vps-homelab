#!/bin/bash
#
# Self-discovering backup for a Docker-based homelab. Archives all named
# Docker volumes plus host-side config that lives outside volumes. Rotates
# old backups. No edits needed when a new container is added.
#
# Replace YOUR_USER and the paths in HOST_PATHS to match your deployment.
#
set -euo pipefail

BACKUP_DIR="/home/YOUR_USER/backups"
RETENTION=7
DATE=$(date +%F_%H-%M-%S)
DEST="${BACKUP_DIR}/${DATE}"

# Volumes to skip on purpose. Large transient SIEM volumes are excluded so
# backups stay small. The queue volume in particular can grow to many GB and
# holds nothing worth restoring.
EXCLUDE=("single-node_wazuh_queue" "single-node_wazuh-indexer-data")

# Host paths outside Docker volumes that you need to rebuild the stack.
HOST_PATHS=(
  "/home/YOUR_USER/wazuh-docker/single-node/docker-compose.yml"
  "/home/YOUR_USER/wazuh-docker/single-node/config"
  "/opt/crowdsec/acquis.yaml"
  "/etc/crowdsec/bouncers"
)

# Discover named volumes, excluding anonymous 64-char hex volumes.
mapfile -t ALL_VOLUMES < <(
  docker volume ls --format '{{ .Name }}' | grep -vE '^[0-9a-f]{64}$'
)

VOLUMES=()
for vol in "${ALL_VOLUMES[@]}"; do
  skip=0
  for ex in "${EXCLUDE[@]:-}"; do
    [[ "${vol}" == "${ex}" ]] && skip=1 && break
  done
  [[ ${skip} -eq 0 ]] && VOLUMES+=("${vol}")
done

mkdir -p "${DEST}"
echo "[*] Backup to ${DEST}"
echo "[*] ${#VOLUMES[@]} Docker volume(s) detected"

for vol in "${VOLUMES[@]}"; do
  echo "    - volume ${vol}"
  docker run --rm \
    -v "${vol}":/data:ro \
    -v "${DEST}":/backup \
    alpine \
    tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null || \
    echo "      ! failed on ${vol} (skipped)"
done

echo "    - host configs"
sudo tar czf "${DEST}/host-configs.tar.gz" "${HOST_PATHS[@]}" 2>/dev/null || \
  echo "      ! some host configs missing (partial)"

{
  echo "Backup ${DATE}"
  echo ""
  echo "Docker volumes:"
  printf '  - %s\n' "${VOLUMES[@]}"
  echo ""
  echo "Host configs:"
  printf '  - %s\n' "${HOST_PATHS[@]}"
} > "${DEST}/MANIFEST.txt"

echo "[*] Rotation (keep last ${RETENTION})"
cd "${BACKUP_DIR}"
ls -1dt */ 2>/dev/null | tail -n +$((RETENTION + 1)) | xargs -r rm -rf

echo "[OK] Backup finished: ${DEST}"
du -sh "${DEST}"
