set -e

echo "======================================"
echo "🔧 FIXING DNS (VAGRANT SAFE)"
echo "======================================"

sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF'

echo "🔄 Restarting Docker..."
sudo systemctl restart docker

echo "✅ DNS FIX APPLIED"
echo "======================================"
echo "🚀 STARTING FULL DEVOPS PIPELINE"
echo "======================================"


echo "🔧 Ensuring Docker setup..."

sudo groupadd docker || true
sudo usermod -aG docker vagrant

echo "⚠️ If Docker fails, run: vagrant reload (once)"


if [ -f .env ]; then
echo "🔐 Loading .env file..."
set -a
source .env
set +a
fi

if [ -z "$DOCKER_USERNAME" ] || [ -z "$DOCKER_PASSWORD" ]; then
echo "❌ Missing DOCKER_USERNAME or DOCKER_PASSWORD"
exit 1
fi


echo "🔐 Logging into Docker Hub..."
echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin

# 1. Add vagrant user to docker group
sudo usermod -aG docker vagrant

# 2. Apply the group change without logout
newgrp docker

# 3. Restart Docker (optional but recommended)
sudo systemctl restart docker
echo "======================================"
echo "📦 FRONTEND BUILD"
echo "======================================"