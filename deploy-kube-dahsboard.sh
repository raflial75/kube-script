#!/bin/bash
# Script: 4-deploy-kubernetes-dashboard.sh
# Deskripsi: Deploy Kubernetes Dashboard dengan beberapa opsi akses
# Jalankan di Master1 atau Master2
# Jalankan sebagai root atau dengan sudo

set -e

echo "================================================"
echo "Deploy Kubernetes Dashboard"
echo "================================================"

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Cek apakah kubectl tersedia
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl tidak ditemukan!"
    exit 1
fi

# Cek koneksi ke cluster
if ! kubectl cluster-info &> /dev/null; then
    print_error "Tidak dapat terkoneksi ke cluster!"
    print_warning "Pastikan kubeconfig sudah di-setup"
    exit 1
fi

print_info "Connected to cluster:"
kubectl cluster-info | head -n 2

echo ""
print_info "Pilih metode akses Dashboard:"
echo "1) NodePort (Recommended untuk testing)"
echo "2) ClusterIP + kubectl proxy (Akses dari master via SSH tunnel)"
echo "3) LoadBalancer via HAProxy (Recommended untuk production)"
echo ""
read -p "Pilih opsi (1/2/3): " ACCESS_METHOD

case $ACCESS_METHOD in
    1)
        ACCESS_TYPE="NodePort"
        ;;
    2)
        ACCESS_TYPE="ClusterIP"
        ;;
    3)
        ACCESS_TYPE="LoadBalancer"
        ;;
    *)
        print_error "Opsi tidak valid!"
        exit 1
        ;;
esac

print_info "Metode akses dipilih: $ACCESS_TYPE"

# Deploy Kubernetes Dashboard
print_info "Deploying Kubernetes Dashboard..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml

# Tunggu deployment selesai
print_info "Waiting for dashboard pods to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=kubernetes-dashboard -n kubernetes-dashboard --timeout=300s

# Create admin service account
print_info "Creating admin service account..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

sleep 3

# Patch service sesuai metode akses
if [ "$ACCESS_TYPE" = "NodePort" ]; then
    print_info "Configuring NodePort access..."
    kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"NodePort"}}'
    
    # Get NodePort
    NODEPORT=$(kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.spec.ports[0].nodePort}')
    
    # Get node IPs
    print_info "Getting node IPs..."
    MASTER1_IP=$(kubectl get node master1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    MASTER2_IP=$(kubectl get node master2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    WORKER1_IP=$(kubectl get node worker1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    WORKER2_IP=$(kubectl get node worker2 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "N/A")
    
elif [ "$ACCESS_TYPE" = "LoadBalancer" ]; then
    print_info "Configuring LoadBalancer type..."
    kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"LoadBalancer"}}'
    
    print_warning "Untuk akses via HAProxy, Anda perlu menambahkan konfigurasi HAProxy!"
    print_warning "Lihat instruksi di bagian akhir script ini."
fi

# Generate token
print_info "Generating admin token..."
TOKEN=$(kubectl -n kubernetes-dashboard create token admin-user --duration=87600h)

# Simpan token ke file
TOKEN_FILE="/root/dashboard-admin-token.txt"
echo "$TOKEN" > $TOKEN_FILE
chmod 600 $TOKEN_FILE

echo ""
echo "================================================"
print_success "Kubernetes Dashboard Deployed Successfully!"
echo "================================================"
echo ""

# Display access information
print_info "Access Information:"
echo ""

if [ "$ACCESS_TYPE" = "NodePort" ]; then
    echo "Dashboard URLs (pilih salah satu):"
    echo "  https://${MASTER1_IP}:${NODEPORT}"
    echo "  https://${MASTER2_IP}:${NODEPORT}"
    [ "$WORKER1_IP" != "N/A" ] && echo "  https://${WORKER1_IP}:${NODEPORT}"
    [ "$WORKER2_IP" != "N/A" ] && echo "  https://${WORKER2_IP}:${NODEPORT}"
    echo ""
    print_warning "Note: Browser akan menampilkan warning SSL, klik 'Advanced' > 'Proceed'"
    
elif [ "$ACCESS_TYPE" = "ClusterIP" ]; then
    echo "Dashboard URL (via kubectl proxy):"
    echo "  1. Jalankan di master: kubectl proxy --address=0.0.0.0 --accept-hosts='.*'"
    echo "  2. Akses dari browser: http://MASTER_IP:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    echo ""
    print_warning "Atau gunakan SSH tunnel:"
    echo "  ssh -L 8001:localhost:8001 root@MASTER_IP"
    echo "  Lalu akses: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    
elif [ "$ACCESS_TYPE" = "LoadBalancer" ]; then
    print_warning "Tambahkan konfigurasi berikut ke HAProxy (/etc/haproxy/haproxy.cfg):"
    echo ""
    cat <<'HAPROXY_CONFIG'
#---------------------------------------------------------------------
# Kubernetes Dashboard Frontend
#---------------------------------------------------------------------
frontend k8s-dashboard-frontend
    bind *:8443
    mode tcp
    option tcplog
    default_backend k8s-dashboard-backend

#---------------------------------------------------------------------
# Kubernetes Dashboard Backend
#---------------------------------------------------------------------
backend k8s-dashboard-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server k8s-master-1 10.8.130.241:NODEPORT check fall 3 rise 2
    server k8s-master-2 10.8.130.242:NODEPORT check fall 3 rise 2
HAPROXY_CONFIG
    echo ""
    print_info "Ganti NODEPORT dengan port actual dari: kubectl get svc -n kubernetes-dashboard"
    echo ""
    print_info "Setelah itu restart HAProxy:"
    echo "  sudo systemctl restart haproxy"
    echo ""
    print_info "Akses dashboard via: https://k8s-api-lb:8443 atau https://192.168.1.5:8443"
fi

echo ""
print_info "Login Token (valid 10 tahun):"
echo "────────────────────────────────────────────────"
echo "$TOKEN"
echo "────────────────────────────────────────────────"
echo ""
print_warning "Token juga disimpan di: $TOKEN_FILE"
echo ""

print_info "Cara login:"
echo "1. Buka Dashboard URL di browser"
echo "2. Pilih 'Token' authentication"
echo "3. Paste token di atas"
echo "4. Click 'Sign In'"
echo ""

# Verification
print_info "Dashboard Status:"
kubectl get all -n kubernetes-dashboard

echo ""
print_info "Untuk mengakses dashboard dari luar cluster, pastikan firewall membuka port yang diperlukan!"

echo ""
print_success "Setup completed! Enjoy your Kubernetes Dashboard! 🎉"
echo ""

# Additional commands
print_info "Useful commands:"
echo "  - Get dashboard service: kubectl get svc -n kubernetes-dashboard"
echo "  - Get dashboard pods: kubectl get pods -n kubernetes-dashboard"
echo "  - Generate new token: kubectl -n kubernetes-dashboard create token admin-user"
echo "  - Delete dashboard: kubectl delete ns kubernetes-dashboard"
echo ""