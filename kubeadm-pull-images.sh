#!/bin/bash
# Script: 3a-pull-images-master.sh
# Deskripsi: Pull images yang diperlukan untuk Kubernetes sebelum init
# Jalankan HANYA di master1
# Jalankan sebagai root atau dengan sudo

set -e

echo "================================================"
echo "Pull Kubernetes Images - Master Node"
echo "================================================"

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Cek apakah running sebagai root
if [ "$EUID" -ne 0 ]; then 
    print_error "Script ini harus dijalankan sebagai root atau dengan sudo"
    exit 1
fi

# Validasi hostname
CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" != "k8s-master-1" ]]; then
    print_warning "Script ini didesain untuk master1, hostname saat ini: $CURRENT_HOSTNAME"
    read -p "Lanjutkan? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ]; then
        print_info "Dibatalkan"
        exit 0
    fi
fi

# Konfigurasi
LB_ENDPOINT="k8s-api-lb:6443"
ADVERTISE_IP=$(hostname -I | awk '{print $1}')
POD_NETWORK_CIDR="10.244.0.0/16"
CRI_SOCKET="unix:///var/run/cri-dockerd.sock"

print_info "Konfigurasi:"
echo "  Control Plane Endpoint: $LB_ENDPOINT"
echo "  Advertise Address: $ADVERTISE_IP"
echo "  Pod Network CIDR: $POD_NETWORK_CIDR"
echo "  CRI Socket: $CRI_SOCKET"
echo ""

# Test koneksi ke load balancer
print_info "Testing connection to load balancer..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/k8s-api-lb/6443" 2>/dev/null; then
    print_info "Load balancer is reachable"
else
    print_error "Cannot connect to load balancer at k8s-api-lb:6443"
    print_warning "Pastikan load balancer sudah running dan dapat diakses"
    exit 1
fi

# Cek status kubelet
print_info "Checking kubelet status..."
if ! systemctl is-enabled --quiet kubelet; then
    print_error "kubelet is not enabled!"
    exit 1
fi

# Cek status Docker dan cri-dockerd
print_info "Checking Docker and cri-dockerd status..."
if ! systemctl is-active --quiet docker; then
    print_error "Docker is not running!"
    exit 1
fi

if ! systemctl is-active --quiet cri-docker; then
    print_error "cri-docker is not running!"
    exit 1
fi

print_info "Docker version: $(docker --version)"
print_info "CRI Docker status: $(systemctl is-active cri-docker)"

# Generate kubeadm config file
print_info "Generating kubeadm configuration..."
tee /root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ADVERTISE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: ${CRI_SOCKET}
  imagePullPolicy: IfNotPresent
  name: ${CURRENT_HOSTNAME}
  taints: null
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: 1.28.0
controlPlaneEndpoint: "${LB_ENDPOINT}"
networking:
  dnsDomain: cluster.local
  podSubnet: ${POD_NETWORK_CIDR}
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

print_info "Kubeadm configuration saved to /root/kubeadm-config.yaml"

# Pull images
print_info "Pulling Kubernetes images..."
echo ""
kubeadm config images pull --config /root/kubeadm-config.yaml --cri-socket=${CRI_SOCKET}

echo ""
print_info "Listing pulled images..."
docker images | grep -E "(kube|pause|coredns|etcd)"

echo ""
echo "================================================"
print_info "Image pull completed successfully!"
echo "================================================"
echo ""
print_info "Images yang sudah di-pull:"
kubeadm config images list --config /root/kubeadm-config.yaml

echo ""
print_warning "Next steps:"
echo "  1. Review kubeadm configuration: cat /root/kubeadm-config.yaml"
echo "  2. Jika sudah OK, jalankan: ./3b-init-master.sh"
echo ""
print_info "Atau jika ingin manual init:"
echo "  sudo kubeadm init --config /root/kubeadm-config.yaml --upload-certs"
echo ""