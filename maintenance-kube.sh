#!/bin/bash
# Script: 8-change-cluster-network.sh
# Deskripsi: Helper untuk migrasi Kubernetes cluster ke network segment baru
# 
# PENTING: Script ini untuk PANDUAN saja, migrasi network perlu dilakukan hati-hati!

set -e

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

print_title() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

echo "========================================================"
echo "Kubernetes Cluster Network Migration Helper"
echo "========================================================"
echo ""

print_warning "PENTING: Migrasi network akan menyebabkan DOWNTIME!"
print_warning "Backup data penting sebelum melanjutkan!"
echo ""

echo "Pilih scenario migrasi:"
echo ""
echo "1) PARTIAL - Ganti IP nodes saja (Pod network tetap)"
echo "2) FULL - Ganti IP nodes + Pod network CIDR"
echo "3) INFO - Lihat informasi network cluster saat ini"
echo "4) BACKUP - Backup konfigurasi penting sebelum migrasi"
echo ""
read -p "Pilih opsi (1/2/3/4): " SCENARIO

case $SCENARIO in
    3)
        # ============================================
        # INFO: Current Network Configuration
        # ============================================
        print_title "Current Cluster Network Configuration"
        echo ""
        
        if ! command -v kubectl &> /dev/null; then
            print_error "kubectl tidak tersedia!"
            exit 1
        fi
        
        print_info "=== Cluster Info ==="
        kubectl cluster-info
        echo ""
        
        print_info "=== Nodes & IPs ==="
        kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
INTERNAL-IP:.status.addresses[0].address,\
EXTERNAL-IP:.status.addresses[1].address,\
HOSTNAME:.status.addresses[2].address
        echo ""
        
        print_info "=== Pod Network CIDR ==="
        kubectl cluster-info dump | grep -m 1 cluster-cidr || echo "N/A"
        echo ""
        
        print_info "=== Service CIDR ==="
        kubectl cluster-info dump | grep -m 1 service-cluster-ip-range || echo "N/A"
        echo ""
        
        print_info "=== CNI Configuration (Flannel) ==="
        kubectl get configmap -n kube-flannel kube-flannel-cfg -o yaml | grep -A 5 net-conf.json || echo "N/A"
        echo ""
        
        print_info "=== API Server Endpoint ==="
        kubectl config view --minify | grep server
        echo ""
        
        print_info "=== etcd Endpoints ==="
        kubectl get pods -n kube-system -l component=etcd -o wide
        echo ""
        
        print_info "=== Load Balancer (jika ada) ==="
        cat /etc/haproxy/haproxy.cfg 2>/dev/null | grep -A 3 "backend k8s-api-backend" || echo "HAProxy not found"
        ;;
        
    4)
        # ============================================
        # BACKUP: Important Configurations
        # ============================================
        print_title "Backup Cluster Configuration"
        echo ""
        
        BACKUP_DIR="/root/k8s-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p $BACKUP_DIR
        
        print_info "Backup directory: $BACKUP_DIR"
        echo ""
        
        # Backup etcd
        if command -v kubectl &> /dev/null; then
            print_info "Backing up etcd..."
            kubectl -n kube-system exec etcd-$(hostname) -- sh -c \
                "ETCDCTL_API=3 etcdctl \
                --endpoints=https://127.0.0.1:2379 \
                --cacert=/etc/kubernetes/pki/etcd/ca.crt \
                --cert=/etc/kubernetes/pki/etcd/server.crt \
                --key=/etc/kubernetes/pki/etcd/server.key \
                snapshot save /tmp/etcd-backup.db" 2>/dev/null || print_warning "etcd backup failed (normal jika bukan master node)"
            
            # Copy etcd backup
            kubectl -n kube-system cp etcd-$(hostname):/tmp/etcd-backup.db $BACKUP_DIR/etcd-backup.db 2>/dev/null || true
        fi
        
        # Backup kubernetes configs
        print_info "Backing up Kubernetes configs..."
        [ -d /etc/kubernetes ] && cp -r /etc/kubernetes $BACKUP_DIR/ || true
        
        # Backup kubeconfig
        print_info "Backing up kubeconfig..."
        [ -d ~/.kube ] && cp -r ~/.kube $BACKUP_DIR/ || true
        
        # Backup manifests
        if command -v kubectl &> /dev/null; then
            print_info "Backing up all resources..."
            kubectl get all --all-namespaces -o yaml > $BACKUP_DIR/all-resources.yaml 2>/dev/null || true
            kubectl get configmaps --all-namespaces -o yaml > $BACKUP_DIR/configmaps.yaml 2>/dev/null || true
            kubectl get secrets --all-namespaces -o yaml > $BACKUP_DIR/secrets.yaml 2>/dev/null || true
            kubectl get pv -o yaml > $BACKUP_DIR/persistent-volumes.yaml 2>/dev/null || true
            kubectl get pvc --all-namespaces -o yaml > $BACKUP_DIR/persistent-volume-claims.yaml 2>/dev/null || true
        fi
        
        # Backup HAProxy
        print_info "Backing up HAProxy config..."
        [ -f /etc/haproxy/haproxy.cfg ] && cp /etc/haproxy/haproxy.cfg $BACKUP_DIR/ || true
        
        # Backup /etc/hosts
        print_info "Backing up /etc/hosts..."
        cp /etc/hosts $BACKUP_DIR/
        
        # Create backup info
        cat > $BACKUP_DIR/README.txt <<EOF
Kubernetes Cluster Backup
========================
Backup Date: $(date)
Hostname: $(hostname)
IP Address: $(hostname -I)

Contents:
- etcd-backup.db (if available)
- /etc/kubernetes/ directory
- ~/.kube/ directory
- all-resources.yaml (all k8s resources)
- configmaps.yaml
- secrets.yaml
- persistent-volumes.yaml
- persistent-volume-claims.yaml
- haproxy.cfg (if available)
- /etc/hosts

Restore Instructions:
See MIGRATION-GUIDE.md for detailed steps
EOF
        
        # Compress backup
        print_info "Compressing backup..."
        tar -czf ${BACKUP_DIR}.tar.gz -C $(dirname $BACKUP_DIR) $(basename $BACKUP_DIR)
        
        echo ""
        print_info "✅ Backup completed!"
        print_info "Backup location: ${BACKUP_DIR}.tar.gz"
        print_info "Backup size: $(du -h ${BACKUP_DIR}.tar.gz | cut -f1)"
        echo ""
        print_warning "PENTING: Copy backup ini ke lokasi aman sebelum migrasi!"
        ;;
        
    1|2)
        # ============================================
        # MIGRATION: Network Change
        # ============================================
        
        if [ "$SCENARIO" = "1" ]; then
            print_title "PARTIAL Migration - Node IP Change Only"
            print_warning "Pod network CIDR akan tetap sama"
        else
            print_title "FULL Migration - Node IP + Pod Network Change"
            print_warning "Semua konfigurasi network akan berubah"
        fi
        
        echo ""
        print_error "=========================================="
        print_error "CRITICAL WARNING!"
        print_error "=========================================="
        print_warning "Migrasi network adalah operasi HIGH RISK!"
        print_warning "- Cluster akan DOWNTIME"
        print_warning "- Semua pods akan restart"
        print_warning "- Connection ke aplikasi akan terputus"
        print_warning "- Data yang tidak persistent akan HILANG"
        echo ""
        print_info "Recommended approach: BUILD NEW CLUSTER"
        print_info "Karena lebih aman daripada migrate existing cluster"
        echo ""
        read -p "Anda yakin ingin melanjutkan migrasi? (yes/no): " CONFIRM
        
        if [ "$CONFIRM" != "yes" ]; then
            print_info "Migrasi dibatalkan"
            exit 0
        fi
        
        echo ""
        print_title "Input Network Configuration"
        echo ""
        
        print_info "=== OLD Network Info ==="
        read -p "OLD Master1 IP: " OLD_MASTER1_IP
        read -p "OLD Master2 IP: " OLD_MASTER2_IP
        read -p "OLD Worker1 IP: " OLD_WORKER1_IP
        read -p "OLD Worker2 IP: " OLD_WORKER2_IP
        read -p "OLD Load Balancer IP: " OLD_LB_IP
        
        echo ""
        print_info "=== NEW Network Info ==="
        read -p "NEW Master1 IP: " NEW_MASTER1_IP
        read -p "NEW Master2 IP: " NEW_MASTER2_IP
        read -p "NEW Worker1 IP: " NEW_WORKER1_IP
        read -p "NEW Worker2 IP: " NEW_WORKER2_IP
        read -p "NEW Load Balancer IP: " NEW_LB_IP
        
        if [ "$SCENARIO" = "2" ]; then
            echo ""
            read -p "NEW Pod Network CIDR [10.244.0.0/16]: " NEW_POD_CIDR
            NEW_POD_CIDR=${NEW_POD_CIDR:-10.244.0.0/16}
            
            read -p "NEW Service CIDR [10.96.0.0/12]: " NEW_SVC_CIDR
            NEW_SVC_CIDR=${NEW_SVC_CIDR:-10.96.0.0/12}
        fi
        
        echo ""
        print_info "=== Summary ==="
        echo "OLD Network:"
        echo "  Master1: $OLD_MASTER1_IP → NEW: $NEW_MASTER1_IP"
        echo "  Master2: $OLD_MASTER2_IP → NEW: $NEW_MASTER2_IP"
        echo "  Worker1: $OLD_WORKER1_IP → NEW: $NEW_WORKER1_IP"
        echo "  Worker2: $OLD_WORKER2_IP → NEW: $NEW_WORKER2_IP"
        echo "  LoadBalancer: $OLD_LB_IP → NEW: $NEW_LB_IP"
        
        if [ "$SCENARIO" = "2" ]; then
            echo "  Pod CIDR: → NEW: $NEW_POD_CIDR"
            echo "  Service CIDR: → NEW: $NEW_SVC_CIDR"
        fi
        
        echo ""
        read -p "Konfirmasi data di atas benar? (yes/no): " CONFIRM2
        
        if [ "$CONFIRM2" != "yes" ]; then
            print_info "Migrasi dibatalkan"
            exit 0
        fi
        
        # Generate migration guide
        GUIDE_FILE="/root/MIGRATION-GUIDE-$(date +%Y%m%d-%H%M%S).md"
        
        cat > $GUIDE_FILE <<EOF
# Kubernetes Cluster Network Migration Guide

Generated: $(date)

## ⚠️ PRE-MIGRATION CHECKLIST

- [ ] Backup etcd: \`./8-change-cluster-network.sh\` → pilih opsi 4
- [ ] Backup /etc/kubernetes directory
- [ ] Backup all application data & persistent volumes
- [ ] Document all external dependencies
- [ ] Notify users about maintenance window
- [ ] Stop all CI/CD pipelines
- [ ] Backup load balancer config

## 📋 MIGRATION STEPS

### RECOMMENDED: Build New Cluster (SAFEST)

Karena migrasi network high risk, cara paling aman adalah:

1. **Build cluster baru dengan network baru**
   - Gunakan script setup yang sama
   - Gunakan IP addresses baru
   
2. **Migrate workloads**
   - Deploy aplikasi ke cluster baru
   - Migrate data via backup/restore
   - Test thoroughly
   
3. **Switch traffic**
   - Update DNS/Load Balancer
   - Decommission old cluster

### ALTERNATIVE: In-Place Migration (HIGH RISK)

Jika tetap ingin migrate in-place:

#### Phase 1: Preparation (All Nodes)

\`\`\`bash
# 1. Drain all worker nodes
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
kubectl drain worker2 --ignore-daemonsets --delete-emptydir-data

# 2. Stop kubelet di semua nodes
systemctl stop kubelet

# 3. Stop containers
docker stop \$(docker ps -q)
\`\`\`

#### Phase 2: Change Node IPs

\`\`\`bash
# Di setiap node:

# 1. Update network configuration
# Rocky Linux - edit /etc/sysconfig/network-scripts/ifcfg-eth0
# Ganti IP address sesuai mapping baru

# 2. Update /etc/hosts
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
$NEW_LB_IP  k8s-api-lb
$NEW_MASTER1_IP master1
$NEW_MASTER2_IP master2
$NEW_WORKER1_IP worker1
$NEW_WORKER2_IP worker2
HOSTS

# 3. Reboot node untuk apply network changes
reboot
\`\`\`

#### Phase 3: Update Load Balancer

\`\`\`bash
# Di Load Balancer node:

# 1. Update HAProxy config
sudo nano /etc/haproxy/haproxy.cfg

# Update backend servers:
backend k8s-api-backend
    server master1 $NEW_MASTER1_IP:6443 check
    server master2 $NEW_MASTER2_IP:6443 check

# 2. Restart HAProxy
sudo systemctl restart haproxy
\`\`\`

#### Phase 4: Update Kubernetes Configs

\`\`\`bash
# Di Master1:

# 1. Update kubeadm config
sudo sed -i 's/$OLD_LB_IP/$NEW_LB_IP/g' /etc/kubernetes/manifests/*.yaml
sudo sed -i 's/$OLD_MASTER1_IP/$NEW_MASTER1_IP/g' /etc/kubernetes/manifests/*.yaml

# 2. Update kubeconfig
sudo sed -i 's/$OLD_LB_IP/$NEW_LB_IP/g' /etc/kubernetes/admin.conf
sudo sed -i 's/$OLD_LB_IP/$NEW_LB_IP/g' ~/.kube/config

# 3. Update kubelet config
sudo nano /var/lib/kubelet/config.yaml
# Update clusterDNS jika perlu

# 4. Start kubelet
sudo systemctl start kubelet
\`\`\`

#### Phase 5: Rejoin Nodes

\`\`\`bash
# Di Master2:
# Reset node
kubeadm reset -f
rm -rf /etc/kubernetes/
rm -rf ~/.kube/

# Rejoin sebagai control plane
# Gunakan join command baru dari master1

# Di Worker Nodes:
# Reset nodes
kubeadm reset -f
rm -rf /etc/kubernetes/

# Rejoin sebagai worker
# Gunakan join command baru dari master1
\`\`\`

EOF

        if [ "$SCENARIO" = "2" ]; then
            cat >> $GUIDE_FILE <<EOF

#### Phase 6: Update Pod Network (FULL Migration Only)

\`\`\`bash
# Di Master1:

# 1. Delete existing CNI
kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 2. Update kubeadm config dengan Pod CIDR baru
sudo nano /root/kubeadm-config.yaml
# Update podSubnet: $NEW_POD_CIDR
# Update serviceSubnet: $NEW_SVC_CIDR

# 3. Reinstall CNI dengan config baru
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 4. Restart all pods untuk apply new network
kubectl delete pods --all --all-namespaces
\`\`\`
EOF
        fi
        
        cat >> $GUIDE_FILE <<EOF

## ✅ POST-MIGRATION VERIFICATION

\`\`\`bash
# 1. Check all nodes
kubectl get nodes -o wide

# 2. Check system pods
kubectl get pods -A

# 3. Check cluster info
kubectl cluster-info

# 4. Test pod connectivity
kubectl run test-pod --image=nginx --rm -it -- /bin/bash

# 5. Test service discovery
kubectl run test-dns --image=busybox --rm -it -- nslookup kubernetes.default

# 6. Test external access
# Access NodePort services dari luar cluster

# 7. Verify persistent volumes
kubectl get pv,pvc -A
\`\`\`

## 🔧 TROUBLESHOOTING

### Issue: Nodes NotReady
\`\`\`bash
kubectl describe node <node-name>
journalctl -u kubelet -f
\`\`\`

### Issue: Pods CrashLoopBackOff
\`\`\`bash
kubectl logs <pod-name> -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
\`\`\`

### Issue: Network connectivity problems
\`\`\`bash
# Check CNI
kubectl get pods -n kube-flannel

# Check pod network
kubectl exec -it <pod> -- ping <other-pod-ip>
\`\`\`

## 📞 ROLLBACK PLAN

Jika migrasi gagal:

1. Restore dari backup etcd
2. Revert network changes
3. Restore /etc/kubernetes configs
4. Restart all services

\`\`\`bash
# Restore etcd
ETCDCTL_API=3 etcdctl snapshot restore /path/to/backup.db

# Restore configs
cp -r /backup/kubernetes/* /etc/kubernetes/

# Restart kubelet
systemctl restart kubelet
\`\`\`

## Network Mapping Summary

| Node | Old IP | New IP |
|------|--------|--------|
| Load Balancer | $OLD_LB_IP | $NEW_LB_IP |
| Master1 | $OLD_MASTER1_IP | $NEW_MASTER1_IP |
| Master2 | $OLD_MASTER2_IP | $NEW_MASTER2_IP |
| Worker1 | $OLD_WORKER1_IP | $NEW_WORKER1_IP |
| Worker2 | $OLD_WORKER2_IP | $NEW_WORKER2_IP |

EOF
        
        if [ "$SCENARIO" = "2" ]; then
            cat >> $GUIDE_FILE <<EOF
| Pod Network | 10.244.0.0/16 | $NEW_POD_CIDR |
| Service Network | 10.96.0.0/12 | $NEW_SVC_CIDR |
EOF
        fi
        
        cat >> $GUIDE_FILE <<EOF

---

**IMPORTANT:** This is a HIGH RISK operation. Consider building a new cluster instead!

Generated by: 8-change-cluster-network.sh
Date: $(date)
EOF
        
        echo ""
        print_info "✅ Migration guide generated!"
        print_info "File: $GUIDE_FILE"
        echo ""
        print_warning "NEXT STEPS:"
        echo "1. Review migration guide: cat $GUIDE_FILE"
        echo "2. Do backup: ./8-change-cluster-network.sh → pilih opsi 4"
        echo "3. Schedule maintenance window"
        echo "4. Follow migration guide step-by-step"
        echo ""
        print_error "ATAU: Build new cluster dengan network baru (RECOMMENDED!)"
        ;;
        
    *)
        print_error "Opsi tidak valid!"
        exit 1
        ;;
esac

echo ""
print_info "Done! 🎉"