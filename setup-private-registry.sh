#!/bin/bash
# Script: 7-setup-private-registry.sh
# Deskripsi: Setup Docker Private Registry untuk Kubernetes
# 
# PART 1: Konfigurasi Docker daemon di SEMUA nodes (master & worker)
# PART 2: Create imagePullSecrets di Kubernetes (jalankan di master)

set -e

echo "================================================"
echo "Setup Private Docker Registry"
echo "================================================"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

echo ""
echo "Pilih metode setup:"
echo "1) Konfigurasi Docker daemon (jalankan di SEMUA nodes)"
echo "2) Create Kubernetes imagePullSecrets (jalankan di master)"
echo "3) Test pull image dari private registry"
echo ""
read -p "Pilih mode (1/2/3): " MODE

case $MODE in
    1)
        # ============================================
        # PART 1: DOCKER DAEMON CONFIGURATION
        # ============================================
        print_info "Mode: Konfigurasi Docker Daemon"
        
        if [ "$EUID" -ne 0 ]; then 
            print_error "Harus dijalankan sebagai root"
            exit 1
        fi
        
        # Input registry info
        read -p "Masukkan Private Registry URL (contoh: registry.example.com:5000): " REGISTRY_URL
        read -p "Username: " REGISTRY_USER
        read -sp "Password: " REGISTRY_PASS
        echo ""
        
        read -p "Apakah registry menggunakan HTTP (insecure)? (y/n): " IS_INSECURE
        
        print_info "Registry URL: $REGISTRY_URL"
        print_info "Username: $REGISTRY_USER"
        
        # Backup docker daemon config
        if [ -f /etc/docker/daemon.json ]; then
            print_info "Backing up existing daemon.json..."
            cp /etc/docker/daemon.json /etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)
        fi
        
        # Create/update daemon.json
        print_info "Updating Docker daemon configuration..."
        
        if [ "$IS_INSECURE" = "y" ]; then
            # Dengan insecure registry
            cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "insecure-registries": ["$REGISTRY_URL"]
}
EOF
            print_warning "Registry ditambahkan sebagai insecure registry"
        else
            # Tanpa insecure (HTTPS/dengan cert)
            cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
        fi
        
        # Login ke private registry
        print_info "Logging in to private registry..."
        echo "$REGISTRY_PASS" | docker login $REGISTRY_URL -u $REGISTRY_USER --password-stdin
        
        # Restart Docker
        print_info "Restarting Docker daemon..."
        systemctl daemon-reload
        systemctl restart docker
        systemctl restart cri-docker
        
        # Verify
        sleep 3
        if systemctl is-active --quiet docker; then
            print_success "Docker daemon restarted successfully!"
        else
            print_error "Docker failed to restart!"
            systemctl status docker
            exit 1
        fi
        
        # Test pull
        print_info "Docker login status:"
        docker info | grep -A 5 "Registry"
        
        # Save credentials untuk reference
        CRED_FILE="/root/registry-credentials.txt"
        cat > $CRED_FILE <<EOF
Registry URL: $REGISTRY_URL
Username: $REGISTRY_USER
Password: $REGISTRY_PASS
Login Command: docker login $REGISTRY_URL -u $REGISTRY_USER
EOF
        chmod 600 $CRED_FILE
        
        echo ""
        print_success "Docker daemon configured!"
        echo ""
        print_warning "Lakukan setup ini di SEMUA nodes (master & worker)"
        echo ""
        print_info "Credentials disimpan di: $CRED_FILE"
        echo ""
        print_info "Next steps:"
        echo "  1. Ulangi setup ini di node lain"
        echo "  2. Jalankan mode 2 di master untuk create imagePullSecrets"
        echo ""
        print_info "Test pull image:"
        echo "  docker pull $REGISTRY_URL/nama-image:tag"
        ;;
        
    2)
        # ============================================
        # PART 2: CREATE IMAGEPULLSECRETS
        # ============================================
        print_info "Mode: Create Kubernetes imagePullSecrets"
        
        # Cek kubectl
        if ! command -v kubectl &> /dev/null; then
            print_error "kubectl tidak ditemukan!"
            exit 1
        fi
        
        # Input registry info
        read -p "Masukkan Private Registry URL: " REGISTRY_URL
        read -p "Username: " REGISTRY_USER
        read -sp "Password: " REGISTRY_PASS
        echo ""
        read -p "Email (optional): " REGISTRY_EMAIL
        REGISTRY_EMAIL=${REGISTRY_EMAIL:-user@example.com}
        
        read -p "Nama secret [regcred]: " SECRET_NAME
        SECRET_NAME=${SECRET_NAME:-regcred}
        
        echo ""
        print_info "Pilih namespace untuk secret:"
        echo "1) default (hanya namespace default)"
        echo "2) kube-system (untuk system pods)"
        echo "3) Semua namespace (akan create di semua namespace existing)"
        echo "4) Custom namespace"
        echo ""
        read -p "Pilih (1/2/3/4): " NS_CHOICE
        
        case $NS_CHOICE in
            1)
                NAMESPACES="default"
                ;;
            2)
                NAMESPACES="kube-system"
                ;;
            3)
                NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
                print_info "Akan create di namespace: $NAMESPACES"
                ;;
            4)
                read -p "Masukkan namespace: " CUSTOM_NS
                NAMESPACES="$CUSTOM_NS"
                
                # Create namespace jika belum ada
                if ! kubectl get namespace $CUSTOM_NS &> /dev/null; then
                    print_info "Creating namespace: $CUSTOM_NS"
                    kubectl create namespace $CUSTOM_NS
                fi
                ;;
            *)
                print_error "Pilihan tidak valid!"
                exit 1
                ;;
        esac
        
        # Create secret di namespace yang dipilih
        for NS in $NAMESPACES; do
            print_info "Creating secret '$SECRET_NAME' in namespace: $NS"
            
            # Hapus secret jika sudah ada
            kubectl delete secret $SECRET_NAME -n $NS 2>/dev/null || true
            
            # Create secret
            kubectl create secret docker-registry $SECRET_NAME \
                --docker-server=$REGISTRY_URL \
                --docker-username=$REGISTRY_USER \
                --docker-password=$REGISTRY_PASS \
                --docker-email=$REGISTRY_EMAIL \
                -n $NS
                
            print_success "Secret created in namespace: $NS"
        done
        
        # Optional: Set sebagai default imagePullSecrets di namespace
        echo ""
        read -p "Set secret ini sebagai default imagePullSecrets? (y/n): " SET_DEFAULT
        
        if [ "$SET_DEFAULT" = "y" ]; then
            for NS in $NAMESPACES; do
                print_info "Patching default ServiceAccount in $NS..."
                kubectl patch serviceaccount default -n $NS -p "{\"imagePullSecrets\":[{\"name\":\"$SECRET_NAME\"}]}"
            done
            print_success "Default ServiceAccount updated!"
            print_info "Pods baru di namespace ini akan otomatis gunakan secret ini"
        fi
        
        # Save reference
        REF_FILE="/root/imagepullsecret-reference.yaml"
        cat > $REF_FILE <<EOF
# Reference: Cara menggunakan imagePullSecrets

# Metode 1: Manual specify di Pod/Deployment
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  namespace: default
spec:
  containers:
  - name: my-app
    image: $REGISTRY_URL/my-app:latest
  imagePullSecrets:
  - name: $SECRET_NAME

---
# Metode 2: Patch ServiceAccount (sudah dilakukan jika pilih 'y' tadi)
# kubectl patch serviceaccount default -n NAMESPACE -p '{"imagePullSecrets":[{"name":"$SECRET_NAME"}]}'

---
# Cara lihat secret:
# kubectl get secret $SECRET_NAME -n NAMESPACE -o yaml

---
# Cara delete secret:
# kubectl delete secret $SECRET_NAME -n NAMESPACE
EOF
        
        echo ""
        print_success "imagePullSecrets created!"
        echo ""
        print_info "Secret name: $SECRET_NAME"
        print_info "Namespaces: $NAMESPACES"
        echo ""
        print_info "Reference file: $REF_FILE"
        echo ""
        print_warning "Cara menggunakan:"
        echo "  1. Otomatis (jika sudah patch ServiceAccount):"
        echo "     - Pod baru akan otomatis pakai secret ini"
        echo ""
        echo "  2. Manual specify di deployment:"
        cat <<'YAML'
spec:
  template:
    spec:
      imagePullSecrets:
      - name: regcred
      containers:
      - name: my-app
        image: registry.example.com:5000/my-app:latest
YAML
        ;;
        
    3)
        # ============================================
        # PART 3: TEST PULL IMAGE
        # ============================================
        print_info "Mode: Test Pull Image"
        
        if ! command -v kubectl &> /dev/null; then
            print_error "kubectl tidak ditemukan!"
            exit 1
        fi
        
        read -p "Masukkan image URL lengkap (registry.example.com:5000/image:tag): " TEST_IMAGE
        read -p "Namespace [default]: " TEST_NS
        TEST_NS=${TEST_NS:-default}
        
        read -p "Nama imagePullSecret [regcred]: " TEST_SECRET
        TEST_SECRET=${TEST_SECRET:-regcred}
        
        # Create test pod
        print_info "Creating test pod..."
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-private-registry
  namespace: $TEST_NS
spec:
  containers:
  - name: test
    image: $TEST_IMAGE
    command: ["sleep", "3600"]
  imagePullSecrets:
  - name: $TEST_SECRET
  restartPolicy: Never
EOF
        
        print_info "Waiting for pod to start..."
        sleep 5
        
        # Check pod status
        POD_STATUS=$(kubectl get pod test-private-registry -n $TEST_NS -o jsonpath='{.status.phase}')
        
        echo ""
        print_info "Pod Status: $POD_STATUS"
        echo ""
        kubectl get pod test-private-registry -n $TEST_NS
        echo ""
        
        if [ "$POD_STATUS" = "Running" ] || [ "$POD_STATUS" = "Succeeded" ]; then
            print_success "Image berhasil di-pull dari private registry!"
        else
            print_warning "Pod belum running, cek events:"
            kubectl describe pod test-private-registry -n $TEST_NS | tail -20
        fi
        
        echo ""
        print_info "Cleanup test pod:"
        echo "  kubectl delete pod test-private-registry -n $TEST_NS"
        ;;
        
    *)
        print_error "Mode tidak valid!"
        exit 1
        ;;
esac

echo ""
print_success "Done! 🎉"
echo ""