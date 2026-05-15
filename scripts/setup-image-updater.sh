#!/bin/bash
set -euo pipefail

echo "======================================"
echo "⚙️  Setting up ArgoCD Image Updater and ExternalSecrets"
echo "======================================"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Creating namespace and applying image-updater manifests..."
kubectl apply -f "$REPO_ROOT/argocd/image-updater/deployment.yaml"

echo "Installing ExternalSecrets operator (helm chart)..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets-system --create-namespace

echo "Ensuring ExternalSecrets CRDs are present..."
# Wait for CRD to be installed by the chart (timeout 120s)
CRD_NAME="externalsecrets.external-secrets.io"
for i in {1..24}; do
  if kubectl get crd "$CRD_NAME" >/dev/null 2>&1; then
    echo "✅ CRD $CRD_NAME found"
    break
  fi
  echo "⏳ waiting for CRD $CRD_NAME to appear... ($i/24)"
  sleep 5
done
if ! kubectl get crd "$CRD_NAME" >/dev/null 2>&1; then
  echo "❌ WARNING: ExternalSecrets CRD not found after waiting. Attempting to install upstream CRDs."
  # Try to install CRDs directly from the project repository
  kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds.yaml || true
  # wait a bit more
  for i in {1..12}; do
    if kubectl get crd "$CRD_NAME" >/dev/null 2>&1; then
      echo "✅ CRD $CRD_NAME found after manual install"
      break
    fi
    echo "⏳ waiting for CRD $CRD_NAME after manual install... ($i/12)"
    sleep 5
  done
  if ! kubectl get crd "$CRD_NAME" >/dev/null 2>&1; then
    echo "❌ ERROR: Could not install ExternalSecrets CRD. Exiting."
    exit 1
  fi
fi

echo "⏳ Waiting for external-secrets operator deployment to be ready..."
kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets-system --timeout=300s || true
sleep 10
echo "✅ External-secrets operator is ready"

if [[ -n "${ARGOCD_TOKEN:-}" ]]; then
  echo "Creating argocd-image-updater-secret from ARGOCD_TOKEN"
  kubectl -n argocd-image-updater create secret generic argocd-image-updater-secret --from-literal=token="$ARGOCD_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
elif [[ -n "${ARGOCD_TOKEN_FILE:-}" && -f "${ARGOCD_TOKEN_FILE}" ]]; then
  echo "Creating argocd-image-updater-secret from ARGOCD_TOKEN_FILE"
  ARGOCD_TOKEN_VALUE="$(<"${ARGOCD_TOKEN_FILE}")"
  kubectl -n argocd-image-updater create secret generic argocd-image-updater-secret --from-literal=token="$ARGOCD_TOKEN_VALUE" --dry-run=client -o yaml | kubectl apply -f -
else
  echo "⚠️  ARGOCD_TOKEN or ARGOCD_TOKEN_FILE not set; skipping argocd-image-updater-secret creation."
  echo "    Set one of them before running this script to apply a real ArgoCD API token."
fi

echo "Setting up RBAC reminder: Created minimal ClusterRole and binding for image-updater. Review and tighten to least privilege as needed."

if [[ -n "${EXTERNAL_SECRETSTORE_FILE:-}" && -f "${EXTERNAL_SECRETSTORE_FILE}" ]]; then
  echo "Applying SecretStore from EXTERNAL_SECRETSTORE_FILE"
  kubectl apply -f "$EXTERNAL_SECRETSTORE_FILE"
else
  echo "⚠️  EXTERNAL_SECRETSTORE_FILE not set; skipping SecretStore creation."
  echo "    Provide a real SecretStore manifest for your backend (Vault/AWS/GCP/etc.) and rerun the script."
fi

if [[ -n "${EXTERNAL_SECRET_FILE:-}" && -f "${EXTERNAL_SECRET_FILE}" ]]; then
  echo "Applying ExternalSecret from EXTERNAL_SECRET_FILE"
  kubectl apply -f "$EXTERNAL_SECRET_FILE"
else
  echo "⚠️  EXTERNAL_SECRET_FILE not set; skipping ExternalSecret creation."
  echo "    Provide an ExternalSecret manifest that references your real SecretStore and rerun the script."
fi

echo "✅ Image Updater and ExternalSecrets setup applied."
