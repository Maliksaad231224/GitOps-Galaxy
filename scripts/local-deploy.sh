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
echo "📌 Step 6: Applying All ArgoCD Applications..."
kubectl apply -f argocd/applications/

echo "=================================================="
echo "🎉 SETUP COMPLETED SUCCESSFULLY!"
echo "=================================================="
echo ""
echo "Useful Commands:"
echo "   argocd app list"
echo "   argocd app get sherlock-app-dev"
echo "   kubectl get pods -A"
echo ""
echo "ArgoCD UI: https://192.168.56.10:30080"
echo "Username: admin"
echo "Password: $ADMIN_PASS"
echo "=================================================="