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
# Resolve job manifest path relative to the script so it works both on host and inside VM
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JOB_MANIFEST="$REPO_ROOT/manifests/db/test-db-job.yaml"

if [ ! -f "$JOB_MANIFEST" ]; then
  echo "Job manifest not found at $JOB_MANIFEST — attempting to refresh repository"
  if command -v git >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && git pull --ff-only) || true
  fi
fi

if [ ! -f "$JOB_MANIFEST" ]; then
  echo "ERROR: Job manifest $JOB_MANIFEST not found. Please ensure the file exists or run 'git pull' in the repo root: $REPO_ROOT"
  exit 1
fi

kubectl apply -f "$JOB_MANIFEST"

echo "Waiting for db-test-ping job pod to be created..."
pod_name=""
for i in {1..30}; do
  pod_name=$(kubectl get pods -n db-layer -l job-name=db-test-ping -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$pod_name" ]; then
    echo "Found pod: $pod_name"
    break
  fi
  sleep 2
done

if [ -z "$pod_name" ]; then
  echo "ERROR: job pod for db-test-ping not created within expected time"
  kubectl get pods -n db-layer -o wide || true
  kubectl get events -n db-layer --sort-by='.lastTimestamp' | tail -n 50 || true
  exit 1
fi

echo "Monitoring pod $pod_name for startup issues..."
start_ts=$(date +%s)
max_wait_for_start=120
while true; do
  phase=$(kubectl get pod "$pod_name" -n db-layer -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  container_state_reason=$(kubectl get pod "$pod_name" -n db-layer -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  if [ "$phase" = "Running" ] || [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
    echo "Pod $pod_name phase: $phase"
    break
  fi
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [ $elapsed -gt $max_wait_for_start ]; then
    echo "ERROR: pod $pod_name still in phase '$phase' after ${elapsed}s; reason: ${container_state_reason}"
    echo "--- kubectl describe pod $pod_name -n db-layer ---"
    kubectl describe pod "$pod_name" -n db-layer || true
    echo "--- Recent events (db-layer) ---"
    kubectl get events -n db-layer --sort-by='.lastTimestamp' | tail -n 100 || true
    echo "--- Pod logs (if any) ---"
    kubectl logs "$pod_name" -n db-layer --all-containers || true
    exit 1
  fi
  sleep 3
done

echo "Waiting for db-test-ping job to complete..."
kubectl wait --for=condition=complete job/db-test-ping -n db-layer --timeout=300s || {
  echo "ERROR: job/db-test-ping did not complete within timeout"
  kubectl get pods -n db-layer -o wide || true
  kubectl get events -n db-layer --sort-by='.lastTimestamp' | tail -n 100 || true
  echo "--- job logs ---"
  kubectl logs job/db-test-ping -n db-layer || true
  exit 1
}

echo "--- DB connectivity test logs ---"
kubectl logs job/db-test-ping -n db-layer || true
echo "✓ Database connectivity test passed"

# ============================================================
# Database Persistence Test
# ============================================================
echo ""
echo "======================================"
echo "🔄 Testing Database Persistence"
echo "======================================"

# Get PostgreSQL pod name
DB_POD=$(kubectl get pods -n db-layer -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=my-db -o jsonpath='{.items[0].metadata.name}')
if [ -z "$DB_POD" ]; then
  echo "ERROR: Could not find PostgreSQL pod"
  exit 1
fi
echo "Found PostgreSQL pod: $DB_POD"

# Get PostgreSQL password from secret
PG_PASSWORD=$(kubectl get secret my-db-postgresql -n db-layer -o jsonpath='{.data.postgres-password}' | base64 -d)

# Step 1: Insert test data
echo ""
echo "Step 1️⃣ : Inserting test data into database..."
kubectl exec -it "$DB_POD" -n db-layer -- psql -U postgres -d startup_db -c "
CREATE TABLE IF NOT EXISTS persistence_test (
  id SERIAL PRIMARY KEY,
  test_name VARCHAR(255),
  created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO persistence_test (test_name) VALUES ('test_data_before_restart');
SELECT * FROM persistence_test;" || {
  echo "ERROR: Failed to insert test data"
  exit 1
}
echo "✅ Test data inserted successfully"

# Step 2: Delete the database pod
echo ""
echo "Step 2️⃣ : Deleting PostgreSQL pod to trigger restart..."
kubectl delete pod "$DB_POD" -n db-layer --wait=false
echo "Pod deletion initiated: $DB_POD"

# Step 3: Wait for pod to restart
echo ""
echo "Step 3️⃣ : Waiting for PostgreSQL pod to restart..."
echo "⏳ Waiting up to 3 minutes for pod to restart..."

# Use exponential backoff to check if pod is back
timeout=180
elapsed=0
pod_restarted=false

while [ $elapsed -lt $timeout ]; do
  NEW_DB_POD=$(kubectl get pods -n db-layer -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=my-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -n "$NEW_DB_POD" ] && [ "$NEW_DB_POD" != "$DB_POD" ]; then
    echo "✅ New pod created: $NEW_DB_POD"
    # Check if pod is ready
    pod_ready=$(kubectl get pod "$NEW_DB_POD" -n db-layer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$pod_ready" = "True" ]; then
      echo "✅ Pod is Ready"
      pod_restarted=true
      break
    fi
  fi
  
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$pod_restarted" = false ]; then
  echo "❌ ERROR: PostgreSQL pod did not restart within timeout"
  kubectl get pods -n db-layer -o wide
  exit 1
fi

# Additional wait to ensure database is fully responsive
echo "⏳ Ensuring database is fully responsive..."
sleep 10

# Step 4: Verify data persistence
echo ""
echo "Step 4️⃣ : Verifying data persistence after restart..."
echo "Querying test data from restarted database..."

# Query the data and capture output
QUERY_OUTPUT=$(kubectl exec "$NEW_DB_POD" -n db-layer -- psql -U postgres -d startup_db -c "SELECT * FROM persistence_test;" 2>&1)
echo "Query output:"
echo "$QUERY_OUTPUT"

# Check if test data exists
if echo "$QUERY_OUTPUT" | grep -q "test_data_before_restart"; then
  echo "✅ Data persistence verified: Test data found after pod restart!"
  echo "✅ Database persistence is properly configured and functional"
else
  echo "❌ ERROR: Test data not found after pod restart"
  echo "Data was lost during restart — persistence may not be properly configured"
  exit 1
fi

# Cleanup test table
echo ""
echo "🧹 Cleaning up test table..."
kubectl exec "$NEW_DB_POD" -n db-layer -- psql -U postgres -d startup_db -c "DROP TABLE persistence_test;" || true

echo ""
echo "======================================"
echo "✅ All Database Tests Passed"
echo "======================================"
echo "✓ Connectivity test: PASSED"
echo "✓ Persistence test: PASSED"
echo "✓ Database setup complete"