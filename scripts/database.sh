#!/bin/bash
set -e

# ============================================================
# Database Setup — Bitnami PostgreSQL via Helm
# ============================================================

# Pre-flight checks
echo "======================================"
echo "🔍 Pre-flight Checks"
echo "======================================"

echo "Checking kubectl connection..."
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "❌ ERROR: Cannot connect to Kubernetes cluster"
  exit 1
fi
echo "✓ kubectl is connected"

echo "Checking cluster node status..."
nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
if [ -z "$nodes" ]; then
  echo "❌ ERROR: No nodes found in cluster"
  exit 1
fi
echo "✓ Cluster has nodes: $nodes"

echo "Checking Helm..."
if ! helm version >/dev/null 2>&1; then
  echo "❌ ERROR: Helm is not available"
  exit 1
fi
echo "✓ Helm is available"

echo "Pre-pulling test job image (postgres:15-alpine)..."
if command -v crictl >/dev/null 2>&1; then
  # K3s environment with containerd
  echo "  Attempting to pre-pull image via crictl..."
  crictl pull postgres:15-alpine 2>/dev/null || echo "  (pre-pull optional, will attempt during pod creation)"
elif command -v docker >/dev/null 2>&1; then
  # Docker environment
  echo "  Attempting to pre-pull image via docker..."
  docker pull postgres:15-alpine 2>/dev/null || echo "  (pre-pull optional, will attempt during pod creation)"
else
  echo "  (no container CLI found, image will be pulled during pod creation)"
fi

echo "✓ Pre-flight checks complete"
echo ""

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
max_wait_for_start=240  # increased from 120 to 240 seconds for image pull
while true; do
  phase=$(kubectl get pod "$pod_name" -n db-layer -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  container_state_reason=$(kubectl get pod "$pod_name" -n db-layer -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  container_state_msg=$(kubectl get pod "$pod_name" -n db-layer -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || echo "")
  
  if [ "$phase" = "Running" ] || [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
    echo "Pod $pod_name phase: $phase"
    break
  fi
  
  now=$(date +%s)
  elapsed=$((now - start_ts))
  
  # Print progress every 30 seconds if still waiting
  if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
    echo "⏳ Still waiting for pod startup (${elapsed}s elapsed)... Phase: $phase, Reason: $container_state_reason"
    if [ -n "$container_state_msg" ]; then
      echo "   Message: $container_state_msg"
    fi
  fi
  
  if [ $elapsed -gt $max_wait_for_start ]; then
    echo "❌ ERROR: pod $pod_name stuck in phase '$phase' after ${elapsed}s"
    echo "   Reason: $container_state_reason"
    if [ -n "$container_state_msg" ]; then
      echo "   Message: $container_state_msg"
    fi
    echo ""
    echo "📋 --- Detailed Pod Description ---"
    kubectl describe pod "$pod_name" -n db-layer || true
    echo ""
    echo "📋 --- Recent Events (db-layer namespace) ---"
    kubectl get events -n db-layer --sort-by='.lastTimestamp' | tail -n 100 || true
    echo ""
    echo "📋 --- Pod Status ---"
    kubectl get pod "$pod_name" -n db-layer -o yaml || true
    echo ""
    echo "⚠️  Troubleshooting tips:"
    echo "   1. If stuck in 'ContainerCreating': Check image pull (docker pull postgres:15-alpine)"
    echo "   2. Check node resources: kubectl top nodes"
    echo "   3. Check node disk space: kubectl describe nodes"
    echo "   4. Review pod events: kubectl get events -n db-layer -w"
    exit 1
  fi
  sleep 3
done

echo "✅ Pod $pod_name is ready"
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

# Get PostgreSQL password from secret using the first available key
PG_PASSWORD=""
for secret_key in postgres-password postgresql-password password; do
  PG_PASSWORD=$(kubectl get secret my-db-postgresql -n db-layer -o "jsonpath={.data.${secret_key}}" 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "$PG_PASSWORD" ]; then
    break
  fi
done

if [ -z "$PG_PASSWORD" ]; then
  echo "ERROR: Could not read PostgreSQL password from secret my-db-postgresql"
  kubectl get secret my-db-postgresql -n db-layer -o yaml || true
  exit 1
fi

# Step 1: Insert test data
echo ""
echo "Step 1️⃣ : Inserting test data into database..."
if ! kubectl exec -i "$DB_POD" -n db-layer -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres -d startup_db -c "
CREATE TABLE IF NOT EXISTS persistence_test (
  id SERIAL PRIMARY KEY,
  test_name VARCHAR(255),
  created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO persistence_test (test_name) VALUES ('test_data_before_restart');
SELECT * FROM persistence_test;
"; then
  echo "❌ ERROR: Failed to insert test data"
  exit 1
fi
echo "✅ Test data inserted successfully"

# Step 2: Delete the database pod
echo ""
echo "Step 2️⃣ : Deleting PostgreSQL pod to trigger restart..."

# Get the original pod's UID to detect when a new instance is created
ORIGINAL_UID=$(kubectl get pod "$DB_POD" -n db-layer -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
echo "Original pod UID: $ORIGINAL_UID"

kubectl delete pod "$DB_POD" -n db-layer --wait=false
echo "Pod deletion initiated: $DB_POD"

# Step 3: Wait for pod to restart
echo ""
echo "Step 3️⃣ : Waiting for PostgreSQL pod to restart..."
echo "⏳ Waiting up to 3 minutes for pod to restart with a new instance..."

# Wait for the pod to be deleted first
echo "Waiting for original pod to be deleted..."
for i in {1..30}; do
  if ! kubectl get pod "$DB_POD" -n db-layer >/dev/null 2>&1; then
    echo "✅ Original pod deleted"
    break
  fi
  sleep 2
done

# Now wait for the pod to be recreated and ready
timeout=180
elapsed=0
pod_restarted=false

while [ $elapsed -lt $timeout ]; do
  NEW_DB_POD=$(kubectl get pods -n db-layer -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=my-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -n "$NEW_DB_POD" ]; then
    # Check if it's a new instance (different UID)
    NEW_UID=$(kubectl get pod "$NEW_DB_POD" -n db-layer -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
    
    if [ -n "$NEW_UID" ] && [ "$NEW_UID" != "$ORIGINAL_UID" ]; then
      echo "✅ New pod instance created: $NEW_DB_POD (UID: $NEW_UID)"
      # Check if pod is ready
      pod_ready=$(kubectl get pod "$NEW_DB_POD" -n db-layer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      if [ "$pod_ready" = "True" ]; then
        echo "✅ Pod is Ready"
        pod_restarted=true
        DB_POD="$NEW_DB_POD"  # Update DB_POD to the new pod name
        break
      fi
    fi
  fi
  
  sleep 5
  elapsed=$((elapsed + 5))
done

if [ "$pod_restarted" = false ]; then
  echo "❌ ERROR: PostgreSQL pod did not restart within timeout"
  echo "Current pod status:"
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
QUERY_OUTPUT=$(kubectl exec -i "$DB_POD" -n db-layer -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres -d startup_db -c "SELECT * FROM persistence_test;" 2>&1)
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
kubectl exec -i "$NEW_DB_POD" -n db-layer -- env PGPASSWORD="$PG_PASSWORD" psql -U postgres -d startup_db -c "DROP TABLE persistence_test;" || true

echo ""
echo "======================================"
echo "✅ All Database Tests Passed"
echo "======================================"
echo "✓ Connectivity test: PASSED"
echo "✓ Persistence test: PASSED"
echo "✓ Database setup complete"