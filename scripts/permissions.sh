# 1. Fix DNS
sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF'

# 2. Restart services
sudo systemctl restart k3s
sudo systemctl restart docker

# 3. Wait a bit
sleep 10

# 4. Test connectivity
echo "=== Testing Internet Access ==="
curl -I https://github.com
curl -I https://charts.bitnami.com