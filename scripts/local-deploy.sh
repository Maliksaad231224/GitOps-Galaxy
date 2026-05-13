#!/bin/bash
set -e

DOCKER_USERNAME="${DOCKER_USERNAME:-tumbaoka}"

echo "======================================"
echo "📦 Building FRONTEND"
echo "======================================"
cd /home/vagrant/project/gitops-helm-argocd-project/src/frontend

docker build -t $DOCKER_USERNAME/sherlock-logs-frontend:latest .

# Tag for all environments
docker tag $DOCKER_USERNAME/sherlock-logs-frontend:latest $DOCKER_USERNAME/sherlock-logs-frontend:dev
docker tag $DOCKER_USERNAME/sherlock-logs-frontend:latest $DOCKER_USERNAME/sherlock-logs-frontend:staging
docker tag $DOCKER_USERNAME/sherlock-logs-frontend:latest $DOCKER_USERNAME/sherlock-logs-frontend:prod

echo "🚀 Pushing FRONTEND images..."
docker push $DOCKER_USERNAME/sherlock-logs-frontend:latest
docker push $DOCKER_USERNAME/sherlock-logs-frontend:dev
docker push $DOCKER_USERNAME/sherlock-logs-frontend:staging
docker push $DOCKER_USERNAME/sherlock-logs-frontend:prod

echo "======================================"
echo "📦 Building BACKEND"
echo "======================================"
cd /home/vagrant/project/gitops-helm-argocd-project/src/backend

docker build -t $DOCKER_USERNAME/sherlock-logs-backend:latest .

# Tag for all environments
docker tag $DOCKER_USERNAME/sherlock-logs-backend:latest $DOCKER_USERNAME/sherlock-logs-backend:dev
docker tag $DOCKER_USERNAME/sherlock-logs-backend:latest $DOCKER_USERNAME/sherlock-logs-backend:staging
docker tag $DOCKER_USERNAME/sherlock-logs-backend:latest $DOCKER_USERNAME/sherlock-logs-backend:prod

echo "🚀 Pushing BACKEND images..."
docker push $DOCKER_USERNAME/sherlock-logs-backend:latest
docker push $DOCKER_USERNAME/sherlock-logs-backend:dev
docker push $DOCKER_USERNAME/sherlock-logs-backend:staging
docker push $DOCKER_USERNAME/sherlock-logs-backend:prod

echo "======================================"
echo "☸️  Updating Helm Values for Dev Environment"
echo "======================================"
cd /home/vagrant/project/gitops-helm-argocd-project

# Update image tags in values files (GitOps friendly)
sed -i "s|tag: .*|tag: latest|" helm-charts/sherlock-app/values.yaml
sed -i "s|tag: .*|tag: dev|" helm-charts/sherlock-app/values-dev.yaml
sed -i "s|tag: .*|tag: staging|" helm-charts/sherlock-app/values-staging.yaml
sed -i "s|tag: .*|tag: prod|" helm-charts/sherlock-app/values-prod.yaml

echo "✅ Image tags updated in Helm values files"

echo "======================================"
echo "📊 Current Cluster Status"
echo "======================================"
kubectl get pods -A
kubectl get svc -A

echo "======================================"
echo "✅ Docker Build & Push Completed Successfully"
echo "======================================"
echo "Next Step: Run './scripts/setup-argocd.sh' to deploy via ArgoCD"


echo "=================================================="
echo "🚀 ArgoCD + Multi-Environment Setup Script"
echo "=================================================="

cd /home/vagrant/project

echo "📌 Step 1: Creating Namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace staging --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -

echo "📌 Step 2: Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd -n argocd --version 7.5.2 \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30080

echo "⏳ Waiting for ArgoCD Server to be ready..."
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s || true

echo "📌 Step 3: Getting Admin Password..."
ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "✅ ArgoCD Admin Password: $ADMIN_PASS"

echo "📌 Step 4: Installing ArgoCD CLI (if not present)..."
if ! command -v argocd &> /dev/null; then
  curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  chmod +x argocd
  sudo mv argocd /usr/local/bin/
fi

# 1. Fix DNS (Most Common Fix)
sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF'

# 2. Restart Docker and k3s
sudo systemctl restart docker
sudo systemctl restart k3s

# 3. Test internet connectivity
ping -c 3 8.8.8.8
ping -c 3 google.com
curl -I https://github.com
curl -I https://charts.bitnami.com


echo "📌 Step 5: Logging into ArgoCD CLI..."
ADMIN_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo $ADMIN_PASS

# 2. Login with all recommended flags
argocd login 192.168.56.10:30080 \
  --username admin \
  --password $ADMIN_PASS \
  --insecure \
  --grpc-web \
  --skip-test-tls
cd ..

echo "📌 Step 6: Fixing DNS Issue (ndots:1 for repo-server)..."
echo "⚠️  Fixing DNS resolution issue in ArgoCD repo-server..."
kubectl patch deployment argocd-repo-server -n argocd --type merge -p '{"spec":{"template":{"spec":{"dnsConfig":{"options":[{"name":"ndots","value":"1"}]}}}}}'
kubectl rollout restart deployment/argocd-repo-server -n argocd
echo "⏳ Waiting for repo-server to be ready..."
kubectl wait --for=condition=Available deployment/argocd-repo-server -n argocd --timeout=300s || true

echo "📌 Step 7: Fixing Helm Chart Structure..."
echo "⚠️  Removing values files from templates directory..."
rm -f helm-charts/sherlock-app/templates/values-*.yaml
echo "✅ Values files removed from templates"

echo "📌 Step 8: Applying All ArgoCD Applications..."
echo "Applying sherlock-app-dev..."
kubectl apply -f argocd/applications/sherlock-app-dev.yaml
echo "Applying sherlock-app-staging..."
kubectl apply -f argocd/applications/sherlock-app-staging.yaml
echo "Applying sherlock-app-prod..."
kubectl apply -f argocd/applications/sherlock-app-prod.yaml
echo "Applying postgres-dev..."
kubectl apply -f argocd/applications/postgres-dev.yaml

echo "📌 Step 9: Syncing All Environments..."
echo ""
echo "🔄 Syncing DEV environment..."
argocd app refresh sherlock-app-dev --hard || true
sleep 2
argocd app sync sherlock-app-dev --force
echo "✅ DEV sync initiated"
echo ""

echo "🔄 Syncing STAGING environment..."
argocd app refresh sherlock-app-staging --hard || true
sleep 2
argocd app sync sherlock-app-staging --force
echo "✅ STAGING sync initiated"
echo ""

echo "🔄 Syncing PROD environment..."
argocd app refresh sherlock-app-prod --hard || true
sleep 2
argocd app sync sherlock-app-prod --force
echo "✅ PROD sync initiated"
echo ""

echo "⏳ Waiting for all pods to be ready..."
echo ""
echo "DEV namespace:"
kubectl wait --for=condition=Ready pod -n dev -l app=frontend --timeout=300s || true
kubectl wait --for=condition=Ready pod -n dev -l app=backend --timeout=300s || true
echo ""

echo "STAGING namespace:"
kubectl wait --for=condition=Ready pod -n staging -l app=frontend --timeout=300s || true
kubectl wait --for=condition=Ready pod -n staging -l app=backend --timeout=300s || true
echo ""

echo "PROD namespace:"
kubectl wait --for=condition=Ready pod -n prod -l app=frontend --timeout=300s || true
kubectl wait --for=condition=Ready pod -n prod -l app=backend --timeout=300s || true
echo ""

echo "📌 Step 10: Verifying Deployment Status..."
echo ""
echo "ArgoCD Applications Status:"
argocd app list
echo ""

echo "DEV Environment Resources:"
kubectl get all -n dev
echo ""

echo "STAGING Environment Resources:"
kubectl get all -n staging
echo ""

echo "PROD Environment Resources:"
kubectl get all -n prod
echo ""

echo "=================================================="
echo "🎉 SETUP COMPLETED SUCCESSFULLY!"
echo "=================================================="
echo ""
echo "📊 Deployment Summary:"
echo "   ✅ ArgoCD installed and configured"
echo "   ✅ DNS issue fixed (ndots:1)"
echo "   ✅ Helm chart structure corrected"
echo "   ✅ All 3 environments synced (dev, staging, prod)"
echo ""
echo "🔗 Useful Commands:"
echo "   argocd app list                               # List all apps"
echo "   argocd app get sherlock-app-dev              # Check dev app status"
echo "   argocd app get sherlock-app-staging          # Check staging app status"
echo "   argocd app get sherlock-app-prod             # Check prod app status"
echo "   kubectl get all -n dev                       # View dev resources"
echo "   kubectl get all -n staging                   # View staging resources"
echo "   kubectl get all -n prod                      # View prod resources"
echo "   kubectl logs -n argocd deployment/argocd-repo-server  # Debug repo-server"
echo ""
echo "🌐 ArgoCD UI: https://192.168.56.10:30080"
echo "Username: admin"
echo "Password: $ADMIN_PASS"
echo ""
echo "❌ Troubleshooting:"
echo "   # If pods are not deploying, check ArgoCD app sync status:"
echo "   argocd app get sherlock-app-dev --refresh"
echo ""
echo "   # If DNS still fails, verify with:"
echo "   kubectl exec -n argocd -ti <repo-server-pod> -- dig github.com"
echo ""
echo "   # To manually sync an app:"
echo "   argocd app sync sherlock-app-dev --force"
echo ""
echo "=================================================="