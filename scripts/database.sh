#!/bin/bash
set -e

# ============================================================
# Database Setup — Bitnami PostgreSQL via Helm
# ============================================================

# Add the Bitnami repo (idempotent)
helm repo add bitnami https://charts.bitnami.com/bitnami > /dev/null 2>&1 || true
helm repo update > /dev/null 2>&1

# Create namespace (idempotent)
kubectl get namespace db-layer > /dev/null 2>&1 || kubectl create namespace db-layer
echo "✓ Namespace db-layer ready"

# Install PostgreSQL — skip if already deployed
if helm status my-db --namespace db-layer > /dev/null 2>&1; then
    echo "✓ PostgreSQL (my-db) already installed, skipping"
else
    echo "Installing PostgreSQL via Bitnami Helm chart..."
    helm install my-db bitnami/postgresql \
      --namespace db-layer \
      --set primary.persistence.enabled=true \
      --set primary.persistence.size=1Gi \
      --set auth.database=startup_db \
      --wait \
      --timeout 5m
    echo "✓ PostgreSQL installed"
fi

# Wait for PostgreSQL pod to be ready
echo "Waiting for PostgreSQL pod to be ready..."
kubectl rollout status statefulset/my-db-postgresql -n db-layer --timeout=3m || true

# Run connectivity test job
# Delete old job first (Jobs are immutable — can't kubectl apply over one)
kubectl delete job db-test-ping -n db-layer --ignore-not-found
kubectl apply -f /home/vagrant/project/manifests/db/test-db-job.yaml

echo "Waiting for db-test-ping job to complete..."
kubectl wait --for=condition=complete job/db-test-ping -n db-layer --timeout=120s || true

echo "--- DB connectivity test logs ---"
kubectl logs job/db-test-ping -n db-layer || true
echo "✓ Database setup complete"