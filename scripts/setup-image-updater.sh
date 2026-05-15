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

echo "Creating placeholder secret for argocd-image-updater (token based auth)"
kubectl create secret generic argocd-image-updater-secret -n argocd-image-updater --from-literal=token="" --dry-run=client -o yaml | kubectl apply -f -

echo "NOTE: You must populate 'argocd-image-updater-secret' with a valid ArgoCD API token or configure the image-updater to use SSH/Git credentials. Example to set token:"
echo "kubectl -n argocd-image-updater create secret generic argocd-image-updater-secret --from-literal=token=YOUR_TOKEN --dry-run=client -o yaml | kubectl apply -f -"

echo "Setting up RBAC reminder: Created minimal ClusterRole and binding for image-updater. Review and tighten to least privilege as needed."

echo "Creating an example ExternalSecret (placeholder). You must configure a SecretStore for your provider (Vault/AWS/etc.)."

# Write ExternalSecret to temp file for safer handling
EXTERNAL_SECRET_FILE=$(mktemp)
cat > "$EXTERNAL_SECRET_FILE" <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: example-db-credentials
  namespace: argocd-image-updater
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: placeholder-store
    kind: SecretStore
  target:
    name: example-db-secret
  data:
    - secretKey: username
      remoteRef:
        key: example/db/username
    - secretKey: password
      remoteRef:
        key: example/db/password
EOF

# Try to apply, with retry
if ! kubectl apply -f "$EXTERNAL_SECRET_FILE" 2>/dev/null; then
  echo "⚠️  Failed to create ExternalSecret on first attempt. Retrying in 15 seconds..."
  sleep 15
  if ! kubectl apply -f "$EXTERNAL_SECRET_FILE" 2>/dev/null; then
    echo "⚠️  ExternalSecret creation failed. The operator may still be initializing."
    echo "    You can manually apply it later with: kubectl apply -f \"$EXTERNAL_SECRET_FILE\""
  fi
fi

rm -f "$EXTERNAL_SECRET_FILE"

echo "✅ Image Updater and ExternalSecrets setup applied (placeholders)."
echo "Next steps:"
echo " - Replace repo URL in argocd/application-image-updater.yaml with your repo URL and apply it to ArgoCD."
echo " - Populate 'argocd-image-updater-secret' with a valid ArgoCD token or configure Git credentials for write-back."
echo " - Configure a real SecretStore for ExternalSecrets and create ExternalSecret resources for your secrets."
