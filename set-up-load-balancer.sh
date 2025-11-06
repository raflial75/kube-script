#!/bin/bash
# Script: 2-setup-loadbalancer.sh
# Deskripsi: Setup HAProxy sebagai load balancer untuk HA Control Plane
# Jalankan di node load balancer (192.168.1.5) atau di salah satu master
# Jalankan sebagai root atau dengan sudo

set -e

echo "================================================"
echo "Setup HAProxy Load Balancer untuk Kubernetes"
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

# Konfigurasi IP addresses
MASTER1_IP="10.8.130.241"
MASTER2_IP="10.8.130.242"
LB_PORT="6443"

print_warning "Konfigurasi default:"
echo "  Master1 IP: $MASTER1_IP"
echo "  Master2 IP: $MASTER2_IP"
echo "  LB Port: $LB_PORT"
echo ""
read -p "Gunakan konfigurasi default? (y/n): " USE_DEFAULT

if [ "$USE_DEFAULT" != "y" ]; then
    read -p "Masukkan IP Master1: " MASTER1_IP
    read -p "Masukkan IP Master2: " MASTER2_IP
    read -p "Masukkan Port LB (default 6443): " LB_PORT
    LB_PORT=${LB_PORT:-6443}
fi

# Update system
print_info "Updating system..."
dnf update -y

# Install HAProxy
print_info "Installing HAProxy..."
dnf install -y haproxy

# Backup konfigurasi original
if [ -f /etc/haproxy/haproxy.cfg ]; then
    print_info "Backing up original haproxy.cfg..."
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d_%H%M%S)
fi

# Konfigurasi HAProxy
print_info "Configuring HAProxy..."
tee /etc/haproxy/haproxy.cfg <<EOF
#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon

    # turn on stats unix socket
    stats socket /var/lib/haproxy/stats

#---------------------------------------------------------------------
# common defaults that all the 'listen' and 'backend' sections will
# use if not designated in their block
#---------------------------------------------------------------------
defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 3000

#---------------------------------------------------------------------
# Kubernetes API Server Frontend
#---------------------------------------------------------------------
frontend k8s-api-frontend
    bind *:${LB_PORT}
    mode tcp
    option tcplog
    default_backend k8s-api-backend

#---------------------------------------------------------------------
# Kubernetes API Server Backend
#---------------------------------------------------------------------
backend k8s-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server k8s-master-1 ${MASTER1_IP}:6443 check fall 3 rise 2
    server k8s-master-2 ${MASTER2_IP}:6443 check fall 3 rise 2

#---------------------------------------------------------------------
# HAProxy Statistics
#---------------------------------------------------------------------
listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats realm HAProxy\ Statistics
    stats auth admin:admin
    stats refresh 30s
EOF

# Disable SELinux untuk HAProxy (jika diperlukan)
print_info "Configuring SELinux for HAProxy..."
setsebool -P haproxy_connect_any 1 2>/dev/null || print_warning "SELinux boolean tidak dapat diset (mungkin sudah disabled)"

# Enable dan start HAProxy
print_info "Starting HAProxy..."
systemctl enable haproxy
systemctl restart haproxy

# Cek status
sleep 2
if systemctl is-active --quiet haproxy; then
    print_info "HAProxy running successfully!"
else
    print_error "HAProxy failed to start!"
    systemctl status haproxy --no-pager
    exit 1
fi

# Disable firewall atau buka port
print_info "Configuring firewall..."
if systemctl is-active --quiet firewalld; then
    print_info "Opening firewall ports..."
    firewall-cmd --permanent --add-port=${LB_PORT}/tcp
    firewall-cmd --permanent --add-port=9000/tcp
    firewall-cmd --reload
else
    print_warning "Firewalld tidak aktif, pastikan port ${LB_PORT} dan 9000 dapat diakses"
fi

echo ""
echo "================================================"
print_info "HAProxy Load Balancer Setup Completed!"
echo "================================================"
echo ""
print_info "Konfigurasi:"
echo "  Frontend: *:${LB_PORT}"
echo "  Backend Servers:"
echo "    - k8s-master-1: ${MASTER1_IP}:6443"
echo "    - k8s-master-2: ${MASTER2_IP}:6443"
echo "  Statistics: http://$(hostname -I | awk '{print $1}'):9000/stats"
echo "    Username: admin"
echo "    Password: admin"
echo ""
print_info "HAProxy Status:"
systemctl status haproxy --no-pager | head -n 10
echo ""
print_warning "Next steps:"
echo "  1. Pastikan semua master nodes sudah menjalankan 1-setup-all-nodes.sh"
echo "  2. Test koneksi ke load balancer: telnet k8s-api-lb ${LB_PORT}"
echo "  3. Jalankan 3a-pull-images-master.sh di master1"
echo "  4. Jalankan 3b-init-master.sh di master1"
echo ""