#!/bin/bash
# Script: 3b-init-master.sh
# Deskripsi: Initialize Kubernetes cluster di master node pertama
# Jalankan HANYA di master1 SETELAH menjalankan 3a-pull-images-master.sh
# Jalankan sebagai root atau dengan sudo

set -e

echo "================================================"
echo "Initialize Kubernetes Cluster - Master1"
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

# Cek apakah running sebagai root
if [ "$EUID" -ne 0 ]; then 
    print_error "Script ini harus dijalankan sebagai root atau dengan sudo"
    exit 1
fi

# Validasi hostname
CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" != "k8s-master-1" ]]; then
    print_warning "Script ini didesain untuk k8s-master-1, hostname saat ini: $CURRENT_HOSTNAME"
    read -p "Lanjutkan? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ]; then
        print_info "Dibatalkan"
        exit 0
    fi
fi

# Cek apakah kubeadm config sudah ada
if [ ! -f /root/kubeadm-config.yaml ]; then
    print_error "Kubeadm config file tidak ditemukan!"
    print_warning "Jalankan 3a-pull-images-master.sh terlebih dahulu"
    exit 1
fi

print_info "Using kubeadm config: /root/kubeadm-config.yaml"
echo ""
cat /root/kubeadm-config.yaml
echo ""

read -p "Lanjutkan dengan konfigurasi di atas? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    print_info "Init dibatalkan"
    exit 0
fi

# Pre-flight checks
print_info "Running pre-flight checks..."
kubeadm init phase preflight --config /root/kubeadm-config.yaml

# Initialize cluster
print_info "Initializing Kubernetes cluster..."
print_warning "Proses ini akan memakan waktu beberapa menit..."
echo ""

INIT_OUTPUT=$(mktemp)
kubeadm init --config /root/kubeadm-config.yaml --upload-certs 2>&1 | tee $INIT_OUTPUT

# Ekstrak join commands
print_info "Extracting join commands..."

# Extract control plane join command
CONTROL_PLANE_JOIN=$(grep -A 2 "control-plane node" $INIT_OUTPUT | tail -n 2)
CERTIFICATE_KEY=$(grep "certificate-key" $INIT_OUTPUT | awk '{print $NF}')

# Extract worker join command
WORKER_JOIN=$(grep -A 1 "kubeadm join" $INIT_OUTPUT | grep -v "control-plane" | tail -n 1)

# Save join commands
JOIN_SCRIPT="/root/kubernetes-join-commands.sh"
tee $JOIN_SCRIPT <<EOF
#!/bin/bash
# Kubernetes Join Commands
# Generated at: $(date)

echo "================================================"
echo "Kubernetes Cluster Join Commands"
echo "================================================"
echo ""

echo "=== JOIN MASTER2 (Control Plane Node) ==="
echo "Jalankan command berikut di master2:"
echo ""
cat <<'MASTER2'
${CONTROL_PLANE_JOIN}
MASTER2
echo ""

echo "Certificate Key (berlaku 2 jam): ${CERTIFICATE_KEY}"
echo ""

echo "=== JOIN WORKER NODES ==="
echo "Jalankan command berikut di worker1 dan worker2:"
echo ""
cat <<'WORKER'
${WORKER_JOIN}
WORKER
echo ""

echo "================================================"
echo "PENTING:"
echo "- Token berlaku selama 24 jam"
echo "- Certificate key berlaku selama 2 jam"
echo "- Simpan file ini untuk referensi"
echo "================================================"
EOF

chmod +x $JOIN_SCRIPT

# Setup kubeconfig untuk user root
print_info "Setting up kubeconfig for root user..."
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
chown $(id -u):$(id -g) /root/.kube/config

# Setup kubeconfig untuk user biasa (jika ada)
if [ ! -z "$SUDO_USER" ]; then
    print_info "Setting up kubeconfig for user: $SUDO_USER"
    USER_HOME=$(eval echo ~$SUDO_USER)
    mkdir -p $USER_HOME/.kube
    cp -i /etc/kubernetes/admin.conf $USER_HOME/.kube/config
    chown -R $SUDO_USER:$SUDO_USER $USER_HOME/.kube
fi

# Install CNI Plugin (Flannel)
print_info "Installing Flannel CNI plugin..."
sleep 5
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Wait for pods to be ready
print_info "Waiting for system pods to be ready..."
sleep 10

echo ""
echo "================================================"
print_success "Kubernetes Cluster Initialized Successfully!"
echo "================================================"
echo ""

# Show cluster info
print_info "Cluster Information:"
kubectl cluster-info

echo ""
print_info "Node Status:"
kubectl get nodes -o wide

echo ""
print_info "System Pods Status:"
kubectl get pods -A

echo ""
echo "================================================"
print_warning "IMPORTANT: Join Commands Saved!"
echo "================================================"
echo ""
print_info "Join commands telah disimpan di: $JOIN_SCRIPT"
print_info "Untuk melihat join commands, jalankan: cat $JOIN_SCRIPT"
echo ""

# Display join commands
print_info "Menampilkan join commands..."
echo ""
$JOIN_SCRIPT

echo ""
echo "================================================"
print_warning "Next Steps:"
echo "================================================"
echo "1. Join master2 ke cluster (gunakan command control-plane di atas)"
echo "2. Join worker nodes ke cluster (gunakan command worker di atas)"
echo "3. Verifikasi semua nodes sudah Ready: kubectl get nodes"
echo ""
print_info "Kubeconfig location: /root/.kube/config"
print_info "Admin config: /etc/kubernetes/admin.conf"
echo ""
print_warning "Jika token/certificate expired, generate baru dengan:"
echo "  kubeadm token create --print-join-command"
echo "  kubeadm init phase upload-certs --upload-certs"
echo ""

# Cleanup
rm -f $INIT_OUTPUT