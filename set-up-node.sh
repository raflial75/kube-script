#!/bin/bash
# Script: 1-setup-all-nodes.sh
# Deskripsi: Setup yang harus dijalankan di SEMUA nodes (Master & Worker)
# Jalankan sebagai root atau dengan sudo

set -e

echo "================================================"
echo "Setup Kubernetes Node - Rocky Linux"
echo "================================================"

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fungsi untuk print dengan warna
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

# Tanya hostname untuk node ini
echo ""
read -p "Masukkan hostname untuk node ini (k8s-master-1/k8s-master-2/k8s-worker-1/k8s-worker-2): " NODE_HOSTNAME
hostnamectl set-hostname $NODE_HOSTNAME
print_info "Hostname diset menjadi: $NODE_HOSTNAME"

# Update /etc/hosts
print_info "Mengkonfigurasi /etc/hosts..."
cat >> /etc/hosts <<EOF

# Kubernetes Cluster Nodes
10.8.130.245 k8s-api-lb
10.8.130.241 k8s-master-1
10.8.130.242 k8s-master-2
10.8.130.243 k8s-worker-1
10.8.130.244 k8s-worker-2
EOF

print_warning "Pastikan IP address di /etc/hosts sudah sesuai dengan environment Anda!"
echo ""
cat /etc/hosts
echo ""
read -p "Apakah /etc/hosts sudah sesuai? (y/n/edit): " HOSTS_CHECK
case $HOSTS_CHECK in
    y)
        print_info "Melanjutkan setup..."
        ;;
    edit)
        print_info "Silakan edit /etc/hosts terlebih dahulu"
        nano /etc/hosts  # atau vi /etc/hosts
        ;;
    *)
        print_info "Setup dibatalkan"
        exit 0
        ;;
esac

# Update system
print_info "Updating system..."
dnf update -y

# Disable firewall
print_info "Disabling firewall..."
systemctl stop firewalld
systemctl disable firewalld

# Disable SELinux
print_info "Disabling SELinux..."
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Disable swap
print_info "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules
print_info "Loading kernel modules..."
tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Setup sysctl parameters
print_info "Configuring sysctl parameters..."
tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

# Install Docker
print_info "Installing Docker..."
dnf install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io

# Configure Docker daemon
print_info "Configuring Docker daemon..."
mkdir -p /etc/docker
tee /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

systemctl daemon-reload
systemctl enable docker
systemctl start docker

print_info "Docker version:"
docker --version

# Install cri-dockerd
print_info "Installing cri-dockerd..."
VER=$(curl -s https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest|grep tag_name | cut -d '"' -f 4|sed 's/v//g')
print_info "Downloading cri-dockerd version: $VER"

wget https://github.com/Mirantis/cri-dockerd/releases/download/v${VER}/cri-dockerd-${VER}.amd64.tgz
tar xvf cri-dockerd-${VER}.amd64.tgz
mv cri-dockerd/cri-dockerd /usr/local/bin/
rm -rf cri-dockerd cri-dockerd-${VER}.amd64.tgz

# Download and install systemd files for cri-dockerd
wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service
wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket

mv cri-docker.socket cri-docker.service /etc/systemd/system/
sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service

systemctl daemon-reload
systemctl enable cri-docker.service
systemctl enable --now cri-docker.socket
systemctl start cri-docker.service

print_info "cri-dockerd status:"
systemctl status cri-docker.service --no-pager | head -n 5

# Add Kubernetes repository
print_info "Adding Kubernetes repository..."
tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# Install Kubernetes tools
print_info "Installing kubelet, kubeadm, kubectl..."
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

systemctl enable kubelet

print_info "Kubernetes version installed:"
kubeadm version
kubelet --version
kubectl version --client

echo ""
echo "================================================"
print_info "Setup completed successfully!"
echo "================================================"
echo ""
print_info "Node: $NODE_HOSTNAME"
print_info "Docker: $(docker --version)"
print_info "kubeadm: $(kubeadm version -o short)"
echo ""
print_warning "Next steps:"
if [[ "$NODE_HOSTNAME" == "master1" ]]; then
    echo "  1. Setup load balancer (jika belum)"
    echo "  2. Jalankan pull-images-master.sh"
    echo "  3. Jalankan init-master.sh pada master1"
elif [[ "$NODE_HOSTNAME" == "master2" ]]; then
    echo "  1. Tunggu master1 selesai di-initialize"
    echo "  2. Join sebagai control-plane node"
else
    echo "  1. Tunggu master1 selesai di-initialize"
    echo "  2. Join sebagai worker node"
fi
echo ""