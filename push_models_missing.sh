#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
REMOTE="${REMOTE:-b2:comfyui-runpod-bucket}"
LOCAL_MODELS="${LOCAL_MODELS:-/mnt/z/AI/mnt/d/StabilityMatrix-win-x64/Data/Models}"

# rclone tuning (adjust if you want)
TRANSFERS="${TRANSFERS:-8}"
CHECKERS="${CHECKERS:-16}"

echo "REMOTE:      ${REMOTE}"
echo "LOCAL_MODELS:${LOCAL_MODELS}"
echo ""

# Get remote directories under models/
mapfile -t REMOTE_DIRS < <(rclone lsf "${REMOTE}/models" --dirs-only 2>/dev/null | sed 's:/*$::')

if [[ ${#REMOTE_DIRS[@]} -eq 0 ]]; then
  echo "ERROR: No remote model directories found at ${REMOTE}/models"
  exit 1
fi

for d in "${REMOTE_DIRS[@]}"; do
  local_dir="${LOCAL_MODELS}/${d}"
  remote_dir="${REMOTE}/models/${d}"

  if [[ -d "${local_dir}" ]]; then
    echo ">>> Upload missing only: ${local_dir} -> ${remote_dir}"
    rclone copy "${local_dir}" "${remote_dir}" \
      --ignore-existing \
      --progress \
      --transfers "${TRANSFERS}" \
      --checkers "${CHECKERS}" \
      --fast-list
    echo ""
  else
    echo ">>> Skip (no local dir): ${local_dir}"
  fi
done

echo "Done."
