# Panduan Eksekusi Script Kubernetes HA Cluster

## 📋 Daftar Script

1. **1-setup-all-nodes.sh** - Setup di SEMUA nodes (Master & Worker)
2. **2-setup-loadbalancer.sh** - Setup HAProxy Load Balancer
3. **3a-pull-images-master.sh** - Pull images Kubernetes di Master1
4. **3b-init-master.sh** - Initialize cluster di Master1

---

## 🚀 Urutan Eksekusi

### Prerequisites
- 4 VM dengan Rocky Linux (2 master, 2 worker)
- 1 VM tambahan untuk load balancer (atau gunakan salah satu master)
- Semua VM bisa saling berkomunikasi
- Internet connection untuk download packages

### Spesifikasi IP (Edit sesuai environment Anda)
```
Load Balancer: 192.168.1.5
Master1:       192.168.1.10
Master2:       192.168.1.11
Worker1:       192.168.1.20
Worker2:       192.168.1.21
```

---

## 📝 Step-by-Step Execution

### STEP 1: Setup Semua Nodes
**Jalankan di: Master1, Master2, Worker1, Worker2**

```bash
# Download script
wget https://your-server/1-setup-all-nodes.sh

# Buat executable
chmod +x 1-setup-all-nodes.sh

# Jalankan sebagai root
sudo ./1-setup-all-nodes.sh
```

**Yang dilakukan:**
- Set hostname
- Update /etc/hosts
- Disable firewall & SELinux
- Disable swap
- Install Docker + cri-dockerd
- Install kubeadm, kubelet, kubectl

**Waktu estimasi:** 5-10 menit per node

---

### STEP 2: Setup Load Balancer
**Jalankan di: Node Load Balancer (192.168.1.5)**

```bash
# Download script
wget https://your-server/2-setup-loadbalancer.sh

# Buat executable
chmod +x 2-setup-loadbalancer.sh

# Jalankan sebagai root
sudo ./2-setup-loadbalancer.sh
```

**Yang dilakukan:**
- Install HAProxy
- Konfigurasi load balancing untuk 2 master nodes
- Setup HAProxy statistics dashboard

**Output:**
- HAProxy running di port 6443 (K8s API)
- Statistics: http://192.168.1.5:9000/stats (user: admin, pass: admin)

**Waktu estimasi:** 2-3 menit

**Verifikasi:**
```bash
# Cek status HAProxy
sudo systemctl status haproxy

# Test koneksi dari master nodes
telnet k8s-api-lb 6443
```

---

### STEP 3A: Pull Images di Master1
**Jalankan di: Master1 SAJA**

```bash
# Download script
wget https://your-server/3a-pull-images-master.sh

# Buat executable
chmod +x 3a-pull-images-master.sh

# Jalankan sebagai root
sudo ./3a-pull-images-master.sh
```

**Yang dilakukan:**
- Generate kubeadm configuration
- Test koneksi ke load balancer
- Pull semua images Kubernetes yang diperlukan

**Output:**
- File konfigurasi: `/root/kubeadm-config.yaml`
- Images ter-pull di Docker

**Waktu estimasi:** 3-5 menit (tergantung internet)

**Verifikasi:**
```bash
# Lihat images yang sudah di-pull
sudo docker images | grep -E "(kube|pause|coredns|etcd)"

# Review konfigurasi
cat /root/kubeadm-config.yaml
```

---

### STEP 3B: Initialize Cluster di Master1
**Jalankan di: Master1 SAJA**

⚠️ **PENTING: Pastikan STEP 3A sudah selesai!**

```bash
# Download script
wget https://your-server/3b-init-master.sh

# Buat executable
chmod +x 3b-init-master.sh

# Jalankan sebagai root
sudo ./3b-init-master.sh
```

**Yang dilakukan:**
- Initialize Kubernetes cluster
- Setup kubeconfig
- Install Flannel CNI
- Generate join commands untuk master2 dan workers

**Output:**
- Cluster ter-initialize
- Join commands di: `/root/kubernetes-join-commands.sh`

**Waktu estimasi:** 5-8 menit

**Verifikasi:**
```bash
# Cek cluster
kubectl cluster-info

# Cek nodes
kubectl get nodes

# Cek pods
kubectl get pods -A

# Lihat join commands
cat /root/kubernetes-join-commands.sh
```

---

### STEP 4: Join Master2
**Jalankan di: Master2**

```bash
# Copy join command dari master1:/root/kubernetes-join-commands.sh
# Command akan seperti ini:

sudo kubeadm join k8s-api-lb:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key> \
  --cri-socket=unix:///var/run/cri-dockerd.sock
```

**Setup kubeconfig di Master2:**
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Verifikasi dari Master1 atau Master2:**
```bash
kubectl get nodes
# Seharusnya muncul master1 dan master2
```

---

### STEP 5: Join Worker Nodes
**Jalankan di: Worker1 dan Worker2**

```bash
# Copy join command dari master1:/root/kubernetes-join-commands.sh
# Command akan seperti ini:

sudo kubeadm join k8s-api-lb:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --cri-socket=unix:///var/run/cri-dockerd.sock
```

**Verifikasi dari Master1 atau Master2:**
```bash
kubectl get nodes
# Seharusnya muncul semua nodes: master1, master2, worker1, worker2
```

---

## ✅ Verifikasi Final

### 1. Cek semua nodes Ready
```bash
kubectl get nodes -o wide
```

Output yang diharapkan:
```
NAME      STATUS   ROLES           AGE   VERSION
master1   Ready    control-plane   10m   v1.28.x
master2   Ready    control-plane   8m    v1.28.x
worker1   Ready    <none>          5m    v1.28.x
worker2   Ready    <none>          5m    v1.28.x
```

### 2. Cek semua system pods running
```bash
kubectl get pods -A
```

### 3. Test deployment
```bash
# Deploy nginx test
kubectl create deployment nginx --image=nginx --replicas=3

# Cek pods
kubectl get pods -o wide

# Expose service
kubectl expose deployment nginx --port=80 --type=NodePort

# Get service
kubectl get svc nginx
```

---

## 🔧 Troubleshooting

### Token Expired?
Generate token baru di master1:
```bash
# Untuk worker nodes
kubeadm token create --print-join-command

# Untuk master nodes
kubeadm init phase upload-certs --upload-certs
kubeadm token create --print-join-command --certificate-key <key-dari-command-diatas>
```

### Node Not Ready?
```bash
# Cek kubelet logs
sudo journalctl -u kubelet -f

# Cek pods
kubectl get pods -n kube-system
kubectl describe pod <pod-name> -n kube-system
```

### Load Balancer Issues?
```bash
# Cek HAProxy
sudo systemctl status haproxy
sudo journalctl -u haproxy -f

# Test connectivity
telnet k8s-api-lb 6443
curl -k https://k8s-api-lb:6443
```

### Docker/CRI Issues?
```bash
# Cek Docker
sudo systemctl status docker

# Cek cri-dockerd
sudo systemctl status cri-docker

# Restart services
sudo systemctl restart docker
sudo systemctl restart cri-docker
```

---

## 📊 Resource Requirements

| Node Type | CPU | RAM | Disk | OS |
|-----------|-----|-----|------|-----|
| Master | 2+ | 2GB+ | 20GB+ | Rocky Linux |
| Worker | 2+ | 2GB+ | 20GB+ | Rocky Linux |
| Load Balancer | 1+ | 512MB+ | 10GB+ | Rocky Linux |

---

## 🔒 Security Notes

1. **Firewall**: Scripts menonaktifkan firewall untuk simplicity. Untuk production, buka port yang diperlukan:
   - Master: 6443, 2379-2380, 10250-10252
   - Worker: 10250, 30000-32767

2. **SELinux**: Scripts set ke permissive. Untuk production, configure proper SELinux policies.

3. **HAProxy Stats**: Ubah default password `admin:admin`

---

## 📞 Support

Jika menemui masalah:
1. Cek logs: `journalctl -u kubelet -f`
2. Cek pods: `kubectl get pods -A`
3. Describe resources: `kubectl describe node <node-name>`

---

## 📚 Referensi

- [Kubernetes Official Docs](https://kubernetes.io/docs/)
- [kubeadm Documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
- [Docker Engine Docs](https://docs.docker.com/engine/)
- [cri-dockerd GitHub](https://github.com/Mirantis/cri-dockerd)

---

**Happy Kuberneting! 🚢**