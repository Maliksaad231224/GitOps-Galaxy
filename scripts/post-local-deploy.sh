#!/bin/bash
set -euo pipefail

echo "======================================"
echo "📌 Post local-deploy tasks: Image Updater, ExternalSecrets, RBAC reminders"
echo "======================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v kubectl &> /dev/null; then
  echo "Applying Image Updater and ExternalSecrets operator..."
  bash "$SCRIPT_DIR/setup-image-updater.sh"
else
  echo "kubectl not found — cannot apply cluster manifests. Please run setup-image-updater.sh inside the cluster/VM where kubectl is configured."
fi

echo "Post-local-deploy complete. Review the notes printed above and configure required secrets."
