#!/bin/bash
set -euo pipefail

# DGX/HGX H200 SXM 8-GPU Setup Script (Pre-Reboot)
# Hardware: 8x H200 SXM 141GB, 4x NVSwitch, 2x AMD EPYC 9535, 2.2TiB RAM
# Host: mn011-6labhz1-h200-0001
# OS: Debian 13 (trixie), kernel 6.12
# Run as root: su - then bash h200-setup-prereboot.sh
# After completion: reboot, then run h200-setup-postreboot.sh
#
# NOTE: Corporate firewall does TLS inspection. All external HTTPS downloads
# use --no-check-certificate / -k and apt repos use trusted=yes to bypass
# certificate verification failures from the MITM proxy.

echo "=== Verifying root ==="
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (su -)"
  exit 1
fi

if [ "${H200_ALLOW_DESTRUCTIVE_PREREBOOT:-0}" != "1" ]; then
  echo "ERROR: This legacy prereboot script formats NVMe devices and is no longer the supported rebuild path."
  echo "Use scripts/h200/h200-rebuild.sh for full automation, or set H200_ALLOW_DESTRUCTIVE_PREREBOOT=1 only if you intend to wipe the scripted NVMe devices."
  exit 1
fi

echo "=== Fixing apt sources (remove cdrom if present) ==="
sed -i '/cdrom/d' /etc/apt/sources.list 2>/dev/null || true

echo "=== Installing base packages ==="
apt update
apt install -y \
  sudo curl wget gnupg2 lsb-release ca-certificates \
  build-essential linux-headers-$(uname -r) \
  git vim htop tmux nvtop \
  numactl hwloc \
  pciutils dkms \
  apt-transport-https \
  rsync parted jq iperf3 \
  python3-pip python3-venv \
  mdadm lvm2

echo "=== Setting up sudo for miverso2 ==="
usermod -aG sudo miverso2

echo "=== Bypassing TLS inspection for external repos ==="
cat > /etc/apt/apt.conf.d/99bypass-tls-inspection << 'EOF'
Acquire::https::developer.download.nvidia.com::Verify-Peer "false";
Acquire::https::nvidia.github.io::Verify-Peer "false";
Acquire::https::apt.releases.hashicorp.com::Verify-Peer "false";
EOF

echo "=== Setting up NVIDIA CUDA repo (debian12 — compatible with trixie) ==="
wget -qO /usr/share/keyrings/cuda-archive-keyring.gpg --no-check-certificate \
  https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-archive-keyring.gpg
echo "deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /" \
  > /etc/apt/sources.list.d/cuda-debian12.list
apt update

echo "=== Installing NVIDIA open kernel module + driver ==="
apt install -y nvidia-kernel-open-dkms

echo "=== Installing CUDA toolkit 12.8 ==="
apt install -y cuda-toolkit-12-8

echo "=== Installing nvidia-fabricmanager (REQUIRED for NVSwitch) ==="
apt install -y nvidia-fabricmanager
systemctl enable nvidia-fabricmanager

echo "=== Installing Docker ==="
apt install -y docker.io
systemctl enable docker

echo "=== Installing NVIDIA Container Toolkit ==="
curl -fsSLk https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/nvidia-container-toolkit.gpg
echo "deb [trusted=yes] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update
apt install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker

echo "=== Installing HashiCorp Enterprise ==="
wget -qO- --no-check-certificate https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor > /etc/apt/trusted.gpg.d/hashicorp.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/hashicorp.gpg trusted=yes] https://apt.releases.hashicorp.com bookworm main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt update
apt install -y nomad-enterprise consul-enterprise
systemctl enable nomad
systemctl enable consul

echo "=== Installing Ollama ==="
curl -fsSLk https://ollama.com/install.sh | sh

echo "=== Setting up NVMe drives ==="
echo "  nvme1n1 (7TB) -> /data (models, vllm cache, vllm env)"
echo "  nvme2n1 (7TB) -> /srv/legion (ollama, docker, nomad, consul, logs)"
echo "  nvme3n1 (7TB) -> /reserve (future use)"

echo "=== Formatting NVMe drives ==="
mkfs.ext4 -L data -m 0 /dev/nvme1n1
mkfs.ext4 -L srv -m 0 /dev/nvme2n1
mkfs.ext4 -L reserve -m 0 /dev/nvme3n1

echo "=== Creating mount points ==="
mkdir -p /data /srv/legion /reserve

echo "=== Adding fstab entries ==="
cat >> /etc/fstab << 'EOF'
/dev/nvme1n1 /data ext4 defaults,noatime,discard 0 2
/dev/nvme2n1 /srv/legion ext4 defaults,noatime,discard 0 2
/dev/nvme3n1 /reserve ext4 defaults,noatime,discard 0 2
EOF

echo "=== Mounting all ==="
mount -a

echo "=== Creating /data directory structure ==="
mkdir -p /data/{models,cache,vllm,tmp}
mkdir -p /data/cache/{pip,triton,torchinductor,huggingface}

echo "=== Creating /srv/legion directory structure ==="
mkdir -p /srv/legion/{ollama,docker,nomad,consul,rabbitmq}
mkdir -p /srv/legion/logs/{vllm,ollama,nomad}

echo "=== Moving docker storage to NVMe ==="
systemctl stop docker 2>/dev/null || true
if [ -d "/var/lib/docker" ] && [ ! -L "/var/lib/docker" ]; then
  rsync -a /var/lib/docker/ /srv/legion/docker/ 2>/dev/null || true
  rm -rf /var/lib/docker
  ln -sf /srv/legion/docker /var/lib/docker
fi

echo "=== Setting up Ollama storage on NVMe ==="
mkdir -p /usr/share/ollama/.ollama
echo "/srv/legion/ollama /usr/share/ollama/.ollama none bind 0 0" >> /etc/fstab
mount -a

echo "=== Configuring Ollama ==="
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'OLLEOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
OLLEOF

echo "=== Creating users and groups ==="
groupadd -f llm
useradd -r -s /bin/false -d /data/vllm vllm 2>/dev/null || true
usermod -aG llm miverso2
usermod -aG llm ollama 2>/dev/null || true
usermod -aG llm vllm
usermod -aG video vllm
usermod -aG render vllm

echo "=== Setting ownership ==="
chown -R ollama:ollama /usr/share/ollama/.ollama
chown -R ollama:llm /srv/legion/ollama
chmod -R 775 /srv/legion/ollama
chown -R vllm:llm /data/vllm /data/models /data/cache /data/tmp
chown -R vllm:llm /srv/legion/logs/vllm

echo "=== Network tuning (EPYC + ConnectX-7) ==="
cat > /etc/sysctl.d/99-h200.conf << 'EOF'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 3240000
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
kernel.numa_balancing = 0
vm.nr_hugepages = 4096
vm.swappiness = 1
EOF
sysctl -p /etc/sysctl.d/99-h200.conf

echo "=== File descriptor limits ==="
cat >> /etc/security/limits.conf << 'EOF'
vllm soft nofile 1048576
vllm hard nofile 1048576
ollama soft nofile 65536
ollama hard nofile 65536
* soft memlock unlimited
* hard memlock unlimited
EOF

echo "=== THP + CPU governor persistence ==="
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

echo "=== Applying THP settings now ==="
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

systemctl daemon-reload

echo ""
echo "==========================================="
echo "  PRE-REBOOT SETUP COMPLETE"
echo "==========================================="
echo ""
echo "  Hardware: 8x H200 SXM 141GB + 4x NVSwitch"
echo "  NVMe:     nvme1n1 -> /data (models/vllm)"
echo "            nvme2n1 -> /srv/legion (services/logs)"
echo "            nvme3n1 -> /reserve (future)"
echo ""
echo "  Next steps:"
echo "  1. reboot"
echo "  2. After reboot, run: bash h200-setup-postreboot.sh"
echo ""
echo "  The reboot is required for the NVIDIA driver to load."
echo "==========================================="
