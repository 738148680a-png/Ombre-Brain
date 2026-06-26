#!/usr/bin/env bash
set -euo pipefail

DEPLOY_USER="${OMBRE_DEPLOY_USER:-ccpanel}"
DEPLOY_GROUP="${OMBRE_DEPLOY_GROUP:-ccpanel}"
DEPLOY_DIR="${OMBRE_DEPLOY_DIR:-/opt/ombre-brain}"
SERVICE_NAME="${OMBRE_SERVICE_NAME:-ombre-brain}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="${DEPLOY_DIR}/.env"
PORT="${OMBRE_PORT:-8000}"

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

as_deploy_user() {
  if [[ "$(id -un)" == "${DEPLOY_USER}" ]]; then
    "$@"
  else
    sudo -u "${DEPLOY_USER}" "$@"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd python3
require_cmd git
if [[ "${EUID}" -ne 0 ]]; then
  require_cmd sudo
fi

if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "Deploy user '${DEPLOY_USER}' does not exist. Create it first or set OMBRE_DEPLOY_USER." >&2
  exit 1
fi

case "${DEPLOY_DIR}" in
  "/"|"/opt"|"/home"|"/usr"|"/var")
    echo "Refusing unsafe OMBRE_DEPLOY_DIR=${DEPLOY_DIR}" >&2
    exit 1
    ;;
esac

python3 - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10+ is required")
print(f"Python OK: {sys.version.split()[0]}")
PY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_URL="${OMBRE_REPO_URL:-}"
if [[ -z "${REPO_URL}" && -d "${CURRENT_ROOT}/.git" ]]; then
  REPO_URL="$(git -C "${CURRENT_ROOT}" config --get remote.origin.url || true)"
fi
REPO_URL="${REPO_URL:-https://github.com/P0luz/Ombre-Brain.git}"

as_root mkdir -p "${DEPLOY_DIR}"
as_root chown -R "${DEPLOY_USER}:${DEPLOY_GROUP}" "${DEPLOY_DIR}"

if [[ -d "${DEPLOY_DIR}/.git" ]]; then
  echo "Updating existing checkout in ${DEPLOY_DIR}"
  as_deploy_user git -C "${DEPLOY_DIR}" pull --ff-only
elif [[ -z "$(find "${DEPLOY_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "Cloning ${REPO_URL} to ${DEPLOY_DIR}"
  as_deploy_user git clone "${REPO_URL}" "${DEPLOY_DIR}"
else
  echo "${DEPLOY_DIR} already exists and is not a git checkout; using existing files."
fi

cd "${DEPLOY_DIR}"

echo "Creating/updating Python virtualenv"
as_deploy_user python3 -m venv "${DEPLOY_DIR}/.venv"
as_deploy_user "${DEPLOY_DIR}/.venv/bin/python" -m pip install --upgrade pip
as_deploy_user "${DEPLOY_DIR}/.venv/bin/pip" install -r "${DEPLOY_DIR}/requirements.txt"

if [[ ! -f "${DEPLOY_DIR}/config.yaml" ]]; then
  echo "Installing config.yaml from config.vps.yaml"
  as_deploy_user cp "${DEPLOY_DIR}/config.vps.yaml" "${DEPLOY_DIR}/config.yaml"
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  read -r -s -p "Gemini API key: " GEMINI_API_KEY
  echo
  if [[ -z "${GEMINI_API_KEY}" ]]; then
    echo "Gemini API key cannot be empty." >&2
    exit 1
  fi
  as_root tee "${ENV_FILE}" >/dev/null <<EOF
OMBRE_CONFIG_PATH=${DEPLOY_DIR}/config.yaml
OMBRE_PORT=${PORT}
OMBRE_MCP_REQUIRE_AUTH=false
OMBRE_COMPRESS_API_KEY=${GEMINI_API_KEY}
OMBRE_EMBED_API_KEY=${GEMINI_API_KEY}
OMBRE_COMPRESS_FORMAT=openai_compat
OMBRE_EMBED_FORMAT=gemini
PYTHONUNBUFFERED=1
EOF
  as_root chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "${ENV_FILE}"
  as_root chmod 600 "${ENV_FILE}"
fi

echo "Installing systemd service"
as_root install -m 0644 "${DEPLOY_DIR}/deploy/vps/ombre-brain.service" "${SERVICE_FILE}"

JOURNALD_CONF="/etc/systemd/journald.conf"
if grep -Eq '^[#[:space:]]*SystemMaxUse=' "${JOURNALD_CONF}"; then
  as_root sed -i 's/^[#[:space:]]*SystemMaxUse=.*/SystemMaxUse=100M/' "${JOURNALD_CONF}"
else
  printf '\nSystemMaxUse=100M\n' | as_root tee -a "${JOURNALD_CONF}" >/dev/null
fi

as_root systemctl restart systemd-journald
as_root systemctl daemon-reload
as_root systemctl enable --now "${SERVICE_NAME}.service"

echo
echo "Service status:"
as_root systemctl status "${SERVICE_NAME}.service" --no-pager -l || true
