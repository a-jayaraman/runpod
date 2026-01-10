#!/usr/bin/env bash
set -euo pipefail

#############################################
# ComfyUI "Today Pack" bootstrap for RunPod
# - Object storage is the source of truth
# - Local disk is a disposable cache
#############################################

rclone config create b2 b2 \
  account "${BACKBLAZE_ID}" \
  key "${BACKBLAZE_KEY}"

###############
# USER CONFIG #
###############

START_DIR="$(pwd)"

# rclone remote name (set via: rclone config)
# Example: "r2" or "b2" or "s3"
RCLONE_REMOTE="${RCLONE_REMOTE:-b2}"

# Bucket name (or top-level path on the remote)
BUCKET="${BUCKET:-comfyui-runpod-bucket}"

# Where ComfyUI lives on the pod (can be ephemeral)
COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"

# Local cache root (ephemeral but fast)
CACHE_ROOT="${CACHE_ROOT:-/cache}"

# Where you want to store the "pack list" (one file listing today's models)
TODAY_PACK_FILE="${TODAY_PACK_FILE:-/workspace/today_pack.txt}"

# ComfyUI listen config
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"

# How often to sync outputs back (seconds)
SYNC_INTERVAL="${SYNC_INTERVAL:-180}"  # 3 minutes

# rclone performance knobs (tune if you want)
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-16}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-16}"

# If true, also sync workflows back periodically (useful if you edit/save workflows)
SYNC_WORKFLOWS="${SYNC_WORKFLOWS:-true}"

#####################
# INTERNAL CONSTANTS #
#####################

REMOTE_BASE="${RCLONE_REMOTE}:${BUCKET}"

REMOTE_MODELS="${REMOTE_BASE}/models"
REMOTE_CUSTOM_NODES="${REMOTE_BASE}/custom_nodes"
REMOTE_WORKFLOWS="${REMOTE_BASE}/workflows"
REMOTE_INPUTS="${REMOTE_BASE}/input"
REMOTE_OUTPUTS="${REMOTE_BASE}/output"

LOCAL_MODELS="${CACHE_ROOT}/models"
LOCAL_CUSTOM_NODES="${CACHE_ROOT}/custom_nodes"
LOCAL_WORKFLOWS="${COMFY_DIR}/user/default/workflows"
LOCAL_INPUTS="${COMFY_DIR}/input"
LOCAL_OUTPUTS="${COMFY_DIR}/output"

LOG_DIR="${CACHE_ROOT}/logs"
mkdir -p "${LOG_DIR}"

RUN_LOG="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

#################
# PRE-FLIGHT     #
#################

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

(apt-get update
apt install -y rsync
apt install -y rclone
apt install -y imagemagick
apt install -y libmagickwand-dev
apt install -y git) >/dev/null 2>&1

git pull origin master

if ! command -v magick >/dev/null 2>&1; then
    echo "magick is not installed. Installing from source..."
    
    (wget https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-12.tar.gz
    tar xzf 7.1.2-12.tar.gz
    cd ImageMagick-7.1.2-12
    ./configure --prefix=/usr/local
    make
    make install
    ldconfig
    cd ..
    rm -rf ImageMagick-*
    rm 7.1.2-12.tar.gz) >/dev/null 2>&1

else
    echo "magick is already installed."
fi
magick --version

need_cmd rclone
need_cmd rsync || true  # not required; just checking if it's present

if [[ ! -d "${COMFY_DIR}" ]]; then
  echo "ComfyUI directory not found at ${COMFY_DIR}."
  echo "Clone/install ComfyUI there first, or set COMFY_DIR."
  exit 1
fi

mkdir -p "${LOCAL_MODELS}" "${LOCAL_CUSTOM_NODES}" "${LOCAL_WORKFLOWS}" "${LOCAL_INPUTS}" "${LOCAL_OUTPUTS}"

echo "Logging to: ${RUN_LOG}"
exec > >(tee -a "${RUN_LOG}") 2>&1

echo "== Today Pack bootstrap =="
echo "Remote: ${REMOTE_BASE}"
echo "ComfyUI: ${COMFY_DIR}"
echo "Cache: ${CACHE_ROOT}"

#######################################
# HELPERS: safe-ish rclone invocations #
#######################################

rclone_common_flags=(
  "--transfers" "${RCLONE_TRANSFERS}"
  "--checkers" "${RCLONE_CHECKERS}"
  "--fast-list"
  "--stats" "15s"
  "--stats-one-line"
  "--retries" "5"
  "--low-level-retries" "10"
)

sync_down_dir() {
  local remote_path="$1"
  local local_path="$2"
  echo ""
  echo ">>> Sync down: ${remote_path} -> ${local_path}"
  rclone sync "${remote_path}" "${local_path}" "${rclone_common_flags[@]}"
}

copy_down_file() {
  local remote_file="$1"
  local local_dir="$2"
  echo ">>> Copy down file: ${remote_file} -> ${local_dir}"
  rclone copyto "${remote_file}" "${local_dir}" "${rclone_common_flags[@]}"
}

sync_up_dir() {
  local local_path="$1"
  local remote_path="$2"
  echo ">>> Sync up: ${local_path} -> ${remote_path}"
  rclone sync "${local_path}" "${remote_path}" "${rclone_common_flags[@]}"
}

################################
# 1) Sync essential directories #
################################

# Pull nodes + workflows so your setup stays consistent
# (If you have a huge custom_nodes folder and only want some, we can refine this.)
sync_down_dir "${REMOTE_CUSTOM_NODES}" "${LOCAL_CUSTOM_NODES}"
sync_down_dir "${REMOTE_WORKFLOWS}" "${LOCAL_WORKFLOWS}"

cd "${COMFY_DIR}/custom_nodes"
for dir in "${LOCAL_CUSTOM_NODES}"/*/; do
    # Extract the directory name only
    DIR_NAME=$(basename "$dir")

    # Check if a file or directory of the same name already exists in the current directory
    if [ -e "$DIR_NAME" ] || [ -L "$DIR_NAME" ]; then
        echo "Skipping: $DIR_NAME already exists in the current directory."
    else
        # Create the symbolic link using the absolute path of the target
        # Using absolute paths for the target helps avoid broken links if the link is moved
        TARGET_PATH=$(readlink -f "$dir")
        ln -s "$TARGET_PATH" "$DIR_NAME"
        if [ $? -eq 0 ]; then
            echo "Created symlink: $DIR_NAME -> $TARGET_PATH"
        else
            echo "Failed to create symlink for $DIR_NAME"
        fi
    fi
done

cd "${COMFY_DIR}"
source .venv/bin/activate
pip install uv

while read -r req; do
  echo "Installing $req"
  pip install --quiet -r "$req"
done < <(find -L custom_nodes -name requirements.txt -type f,l)

###########################################
# 3) Wire ComfyUI dirs to the local cache #
###########################################

echo ""
echo ">>> Mapping ComfyUI model paths to cache"

# copy_down_file "${REMOTE_BASE}/config/extra_model_paths.yaml" "${COMFY_DIR}/extra_model_paths.yaml"
cp "${START_DIR}/extra_model_paths.yaml" "${COMFY_DIR}/extra_model_paths.yaml"

sed -i "s|__CACHE_ROOT__|${CACHE_ROOT}|g" "${COMFY_DIR}/extra_model_paths.yaml"

echo "extra_model_paths.yaml file copied from object store"

########################################
# 2) Pull the model "today pack" only  #
########################################

# copy_down_file "${REMOTE_BASE}/today_pack.txt" "${TODAY_PACK_FILE}"
cp "${START_DIR}/today_pack.txt" "${TODAY_PACK_FILE}"

if [[ ! -f "${TODAY_PACK_FILE}" ]]; then
  cat > "${TODAY_PACK_FILE}" <<'EOF'
# Put ONE remote-relative path per line (relative to bucket root).
# Examples (these are examples, replace with your real paths):
# models/checkpoints/sd_xl_base_1.0.safetensors
# models/vae/sdxl_vae.safetensors
# models/loras/your_lora_01.safetensors
# models/loras/your_lora_02.safetensors
#
# Lines starting with # are ignored.
EOF
  echo ""
  echo "Created a starter today pack file at: ${TODAY_PACK_FILE}"
  echo "Edit it, then re-run the script."
  exit 0
fi

echo ""
echo ">>> Reading today pack list: ${TODAY_PACK_FILE}"

# Copy only files listed in TODAY_PACK_FILE
# Each line should be a path like: models/checkpoints/foo.safetensors
while IFS= read -r line; do
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${line}" ]] && continue
  [[ "${line}" =~ ^# ]] && continue

  # Detect directories by trailing slash
  if [[ "${line}" == */ ]]; then
    # Strip trailing slash so dirname/basename behave sanely
    line_no_slash="${line%/}"
    remote_dir="${REMOTE_BASE}/${line_no_slash}/"

    # IMPORTANT: copy into the matching directory so contents don't spill upward
    local_dir="${CACHE_ROOT}/${line_no_slash}"
    mkdir -p "${local_dir}"

    echo ">>> Copy down dir: ${remote_dir} -> ${local_dir}"
    rclone copy "${remote_dir}" "${local_dir}" "${rclone_common_flags[@]}"
  else
    remote_file="${REMOTE_BASE}/${line}"
    local_target_dir="${CACHE_ROOT}/$(dirname "${line}")"
    mkdir -p "${local_target_dir}"

    echo ">>> Copy down file: ${remote_file} -> ${local_target_dir}"
    rclone copy "${remote_file}" "${local_target_dir}" "${rclone_common_flags[@]}"
  fi
done < "${TODAY_PACK_FILE}"

###########################################
# 4) Background sync-up loop for outputs   #
###########################################

sync_loop_pid=""

sync_loop() {
  echo ""
  echo ">>> Starting background sync loop every ${SYNC_INTERVAL}s"
  while true; do
    sleep "${SYNC_INTERVAL}" || true

    # Sync outputs up (this is the main thing that saves your ass)
    sync_up_dir "${LOCAL_OUTPUTS}" "${REMOTE_OUTPUTS}"

    if [[ "${SYNC_WORKFLOWS}" == "true" ]]; then
      sync_up_dir "${LOCAL_WORKFLOWS}" "${REMOTE_WORKFLOWS}"
    fi
  done
}

cleanup() {
  echo ""
  echo ">>> Cleanup triggered (exit). Final sync so you don't lose your work."
  if [[ -n "${sync_loop_pid}" ]]; then
    kill "${sync_loop_pid}" >/dev/null 2>&1 || true
    wait "${sync_loop_pid}" >/dev/null 2>&1 || true
  fi

  # Final sync on exit
  sync_up_dir "${LOCAL_OUTPUTS}" "${REMOTE_OUTPUTS}"
  if [[ "${SYNC_WORKFLOWS}" == "true" ]]; then
    sync_up_dir "${LOCAL_WORKFLOWS}" "${REMOTE_WORKFLOWS}"
  fi
  echo ">>> Done."
}

sync_loop &
sync_loop_pid="$!"

trap cleanup EXIT INT TERM

###########################################
# 5) Launch ComfyUI                         #
###########################################

# echo ""
# echo ">>> Launching ComfyUI on ${COMFY_HOST}:${COMFY_PORT}"
# echo "If you exposed port ${COMFY_PORT} via RunPod, open it in your browser."
# echo ""

# python main.py --listen "${COMFY_HOST}" --port "${COMFY_PORT}"
