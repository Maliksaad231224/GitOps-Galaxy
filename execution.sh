cd project/scripts

chmod +x scripts/*.sh

./docker.sh
./kubernetes.sh
./dockerPermissions.sh
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Add Helm repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
./permissions.sh
dir=$(pwd)
echo "Current directory: $dir"
./local-deploy.sh
dir=$(pwd)
echo "Current directory: $dir"
./database