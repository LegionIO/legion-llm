#!/bin/bash
set -euo pipefail

# Apollo 6500 Gen10 - V100 SXM2 Setup Script (Pre-Reboot)
# Run as root: su - then bash apollo-setup-prereboot.sh
# After completion: reboot, then run apollo-setup-postreboot.sh

OPTUM_CA_PATH="/home/miverso2/Optum_Internal_CA_Full_Chains_bundle.pem"

echo "=== Verifying root ==="
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (su -)"
  exit 1
fi

echo "=== Fixing apt sources (remove cdrom) ==="
sed -i '/cdrom/d' /etc/apt/sources.list

echo "=== Installing base packages ==="
apt update
apt install -y \
  sudo curl wget gnupg2 lsb-release ca-certificates \
  build-essential linux-headers-$(uname -r) \
  git vim htop tmux nvtop \
  numactl hwloc \
  pciutils dkms \
  apt-transport-https software-properties-common \
  rsync parted jq iperf3

echo "=== Setting up sudo for miverso2 ==="
usermod -aG sudo miverso2

echo "=== Installing Optum CA certificate ==="
if [ -f "$OPTUM_CA_PATH" ]; then
  cp "$OPTUM_CA_PATH" /usr/local/share/ca-certificates/optum-internal.crt
  update-ca-certificates
  echo "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt" >> /etc/environment
  echo "NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt" >> /etc/environment
else
  echo "WARNING: Optum CA bundle not found at $OPTUM_CA_PATH, skipping"
fi

echo "=== Setting up NVIDIA CUDA repo ==="
wget -qO /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i /tmp/cuda-keyring.deb
echo 'APT::Key::gpgvcommand "gpgv";' > /etc/apt/apt.conf.d/99force-gpgv
wget -qO- https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/cuda.gpg
echo "deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64 /" \
  > /etc/apt/sources.list.d/cuda-debian12-x86_64.list
apt update

echo "=== Installing NVIDIA driver 580 (V100 legacy) ==="
apt install -y nvidia-driver-pinning-580
apt install -y \
  nvidia-driver=580.126.20-1 \
  nvidia-kernel-dkms=580.126.20-1 \
  nvidia-kernel-support=580.126.20-1 \
  firmware-nvidia-gsp=580.126.20-1 \
  libnvidia-ml1=580.126.20-1 \
  libcuda1=580.126.20-1 \
  nvidia-driver-cuda=580.126.20-1 \
  nvidia-driver-libs=580.126.20-1 \
  nvidia-smi=580.126.20-1

echo "=== Verifying DKMS ==="
dkms status | grep "nvidia/580"
if [ $? -ne 0 ]; then
  echo "ERROR: NVIDIA 580 DKMS module not found"
  exit 1
fi

echo "=== Installing CUDA toolkit 12.6 ==="
apt install -y cuda-toolkit-12-6

echo "=== Installing Docker ==="
apt install -y docker.io
systemctl enable docker

echo "=== Installing NVIDIA Container Toolkit ==="
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/nvidia-container-toolkit.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update
apt install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker

echo "=== Installing HashiCorp Enterprise ==="
wget -qO- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/hashicorp.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt update
apt install -y nomad-enterprise consul-enterprise
systemctl enable nomad
systemctl enable consul

echo "=== Installing Ollama ==="
curl -fsSL https://ollama.com/install.sh | sh

echo "=== Discovering data drive ==="
DATA_DISK=""
for disk in /dev/sd?; do
  if ! mount | grep -q "^${disk}"; then
    SIZE=$(lsblk -bno SIZE "$disk" 2>/dev/null | head -1)
    if [ -n "$SIZE" ] && [ "$SIZE" -gt 1000000000000 ]; then
      DATA_DISK="$disk"
      echo "Found data drive: $DATA_DISK ($(lsblk -no SIZE $DATA_DISK | head -1))"
      break
    fi
  fi
done

if [ -z "$DATA_DISK" ]; then
  echo "WARNING: No large unpartitioned data drive found. Checking for existing partitions..."
  lsblk
  echo "You may need to manually partition the data drive."
  exit 1
fi

echo "=== Partitioning data drive: $DATA_DISK ==="
parted "$DATA_DISK" mklabel gpt
parted "$DATA_DISK" mkpart ollama ext4 0% 512GB
parted "$DATA_DISK" mkpart docker ext4 512GB 562GB
parted "$DATA_DISK" mkpart nomad-data ext4 562GB 612GB
parted "$DATA_DISK" mkpart consul ext4 612GB 622GB
parted "$DATA_DISK" mkpart nomad-log ext4 622GB 672GB
parted "$DATA_DISK" mkpart rabbitmq ext4 672GB 722GB
parted "$DATA_DISK" mkpart ollama-log ext4 722GB 732GB
parted "$DATA_DISK" mkpart vllm-log ext4 732GB 742GB
parted "$DATA_DISK" mkpart data ext4 742GB 100%

echo "=== Formatting partitions ==="
mkfs.ext4 -L ollama "${DATA_DISK}1"
mkfs.ext4 -L docker "${DATA_DISK}2"
mkfs.ext4 -L nomad-data "${DATA_DISK}3"
mkfs.ext4 -L consul "${DATA_DISK}4"
mkfs.ext4 -L nomad-log "${DATA_DISK}5"
mkfs.ext4 -L rabbitmq "${DATA_DISK}6"
mkfs.ext4 -L ollama-log "${DATA_DISK}7"
mkfs.ext4 -L vllm-log "${DATA_DISK}8"
mkfs.ext4 -L data "${DATA_DISK}9"

echo "=== Creating mount points ==="
mkdir -p /srv/ollama /var/lib/docker /opt/nomad /opt/consul \
  /var/log/nomad /var/lib/rabbitmq /var/log/ollama /var/log/vllm /data

echo "=== Adding fstab entries ==="
cat >> /etc/fstab << EOF
${DATA_DISK}1 /srv/ollama ext4 defaults,noatime 0 2
${DATA_DISK}2 /var/lib/docker ext4 defaults,noatime 0 2
${DATA_DISK}3 /opt/nomad ext4 defaults,noatime 0 2
${DATA_DISK}4 /opt/consul ext4 defaults,noatime 0 2
${DATA_DISK}5 /var/log/nomad ext4 defaults,noatime 0 2
${DATA_DISK}6 /var/lib/rabbitmq ext4 defaults,noatime 0 2
${DATA_DISK}7 /var/log/ollama ext4 defaults,noatime 0 2
${DATA_DISK}8 /var/log/vllm ext4 defaults,noatime 0 2
${DATA_DISK}9 /data ext4 defaults,noatime 0 2
EOF

echo "=== Mounting all ==="
mount -a

echo "=== Creating data directory structure ==="
mkdir -p /data/{models,cache,vllm,tmp,logs}
mkdir -p /data/cache/{pip,triton,torchinductor}

echo "=== Setting up Ollama bind mount ==="
mkdir -p /usr/share/ollama/.ollama/models
echo "/srv/ollama /usr/share/ollama/.ollama none bind 0 0" >> /etc/fstab
mount -a

echo "=== Configuring Ollama ==="
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
EOF

echo "=== Creating users and groups ==="
groupadd -f llm
useradd -r -s /bin/false -d /data/vllm vllm 2>/dev/null || true
usermod -aG llm miverso2
usermod -aG llm ollama
usermod -aG llm vllm
usermod -aG video vllm
usermod -aG render vllm

echo "=== Setting ownership ==="
chown -R ollama:ollama /usr/share/ollama/.ollama
chown -R ollama:llm /srv/ollama
chmod -R 775 /srv/ollama
chown -R vllm:llm /data/vllm /data/models /data/cache /data/tmp /var/log/vllm

echo "=== Network tuning ==="
cat > /etc/sysctl.d/99-optum.conf << 'EOF'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 3240000
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
kernel.numa_balancing = 0
vm.nr_hugepages = 1024
EOF
sysctl -p /etc/sysctl.d/99-optum.conf

echo "=== File descriptor limits ==="
cat >> /etc/security/limits.conf << 'EOF'
vllm soft nofile 65536
vllm hard nofile 65536
ollama soft nofile 65536
ollama hard nofile 65536
EOF

echo "=== THP tuning ==="
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > $gov 2>/dev/null
done
exit 0
RCEOF
chmod +x /etc/rc.local

echo "=== Disabling nvidia-fabricmanager (not needed for Apollo 6500) ==="
systemctl disable nvidia-fabricmanager 2>/dev/null || true

systemctl daemon-reload

echo ""
echo "==========================================="
echo "  PRE-REBOOT SETUP COMPLETE"
echo "==========================================="
echo ""
echo "  Next steps:"
echo "  1. reboot"
echo "  2. After reboot, run: bash apollo-setup-postreboot.sh"
echo ""
echo "  The reboot is required for the NVIDIA 580 driver to load."
echo "==========================================="
