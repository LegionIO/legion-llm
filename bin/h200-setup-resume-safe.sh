#!/bin/bash
set -euo pipefail

# Safe H200 setup resume script.
# Goal: finish mounts + runtime services after GPU PCI BAR recovery.
# This script refuses destructive disk formatting unless H200_ALLOW_FORMAT=1.

MODEL_DIR="${MODEL_DIR:-/data/models/qwen3.6-27b}"
VLLM_PORT="${VLLM_PORT:-8000}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

echo "=== Verifying root ==="
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (su -)"
  exit 1
fi

echo "=== Verifying H200 PCI BAR recovery ==="
if ! grep -qw 'pci=realloc=off' /proc/cmdline; then
  echo "ERROR: pci=realloc=off is not active."
  echo "Current cmdline: $(cat /proc/cmdline)"
  exit 1
fi

for bdf in 04 14 64 77 84 94 e9 f6; do
  resource="/sys/bus/pci/devices/0000:${bdf}:00.0/resource"
  if [ ! -r "$resource" ]; then
    echo "ERROR: GPU 0000:${bdf}:00.0 is missing from sysfs."
    exit 1
  fi
  if ! awk 'NR==1||NR==3||NR==5 { if ($1 == "0x0000000000000000") bad = 1 } END { exit bad }' "$resource"; then
    echo "ERROR: GPU 0000:${bdf}:00.0 has an unassigned BAR."
    awk 'NR==1||NR==3||NR==5{print}' "$resource"
    exit 1
  fi
done

echo "=== Verifying NVIDIA stack ==="
timeout 60 nvidia-smi -L
GPU_COUNT="$(timeout 60 nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)"
if [ "$GPU_COUNT" -ne 8 ]; then
  echo "ERROR: Expected 8 H200 GPUs, found $GPU_COUNT"
  exit 1
fi

systemctl enable nvidia-fabricmanager nvidia-persistenced >/dev/null 2>&1 || true
systemctl restart nvidia-fabricmanager
systemctl start nvidia-persistenced || true
systemctl is-active --quiet nvidia-fabricmanager

echo "=== Ensuring packages ==="
apt update
apt install -y \
  sudo curl wget gnupg2 lsb-release ca-certificates \
  build-essential "linux-headers-$(uname -r)" \
  git vim htop tmux nvtop numactl hwloc pciutils dkms \
  apt-transport-https rsync parted jq iperf3 \
  python3-pip python3-venv \
  mdadm lvm2 docker.io

echo "=== Ensuring NVIDIA container toolkit ==="
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  curl -fsSLk https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor > /etc/apt/trusted.gpg.d/nvidia-container-toolkit.gpg
  echo "deb [trusted=yes] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt update
  apt install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl enable docker

echo "=== Ensuring Nomad and Consul packages ==="
if ! command -v nomad >/dev/null 2>&1 || ! command -v consul >/dev/null 2>&1; then
  if [ ! -f /etc/apt/trusted.gpg.d/hashicorp.gpg ]; then
    wget -qO- --no-check-certificate https://apt.releases.hashicorp.com/gpg | \
      gpg --dearmor > /etc/apt/trusted.gpg.d/hashicorp.gpg
  fi
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/hashicorp.gpg trusted=yes] https://apt.releases.hashicorp.com bookworm main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt update
  apt install -y nomad-enterprise consul-enterprise
fi

ensure_ext4_mount() {
  local dev="$1"
  local label="$2"
  local mountpoint="$3"

  if [ ! -b "$dev" ]; then
    echo "ERROR: $dev does not exist"
    exit 1
  fi

  local fstype
  fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
  if [ -z "$fstype" ]; then
    if [ "${H200_ALLOW_FORMAT:-0}" != "1" ]; then
      echo "ERROR: $dev has no filesystem. Refusing to format without H200_ALLOW_FORMAT=1."
      exit 1
    fi
    mkfs.ext4 -F -L "$label" -m 0 "$dev"
  fi

  mkdir -p "$mountpoint"
  if ! grep -Eq "[[:space:]]$mountpoint[[:space:]]" /etc/fstab; then
    echo "LABEL=$label $mountpoint ext4 defaults,noatime,discard 0 2" >> /etc/fstab
  fi
}

echo "=== Ensuring NVMe mounts ==="
ensure_ext4_mount /dev/nvme1n1 data /data
ensure_ext4_mount /dev/nvme2n1 srv /srv/legion
ensure_ext4_mount /dev/nvme3n1 reserve /reserve
mount -a
mountpoint -q /data
mountpoint -q /srv/legion

echo "=== Ensuring directories ==="
mkdir -p /data/{models,cache,vllm,tmp}
mkdir -p /data/cache/{pip,triton,torchinductor,huggingface}
mkdir -p /srv/legion/{ollama,docker,nomad,consul,rabbitmq}
mkdir -p /srv/legion/logs/{vllm,ollama,nomad,consul}

echo "=== Ensuring Docker storage on /srv/legion ==="
systemctl stop docker 2>/dev/null || true
if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
  rsync -a /var/lib/docker/ /srv/legion/docker/ 2>/dev/null || true
  rm -rf /var/lib/docker
fi
ln -sfn /srv/legion/docker /var/lib/docker
systemctl start docker

echo "=== Ensuring Ollama ==="
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSLk https://ollama.com/install.sh | sh
fi
mkdir -p /usr/share/ollama/.ollama
if ! grep -q '/usr/share/ollama/.ollama' /etc/fstab; then
  echo "/srv/legion/ollama /usr/share/ollama/.ollama none bind 0 0" >> /etc/fstab
fi
mount -a
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
EOF

echo "=== Ensuring users/groups/ownership ==="
groupadd -f llm
useradd -r -s /bin/false -d /data/vllm vllm 2>/dev/null || true
usermod -aG llm vllm
usermod -aG video vllm
usermod -aG render vllm
usermod -aG llm ollama 2>/dev/null || true
id miverso2 >/dev/null 2>&1 && usermod -aG sudo,llm miverso2 || true
chown -R ollama:ollama /usr/share/ollama/.ollama
chown -R ollama:llm /srv/legion/ollama
chmod -R 775 /srv/legion/ollama
chown -R vllm:llm /data/vllm /data/models /data/cache /data/tmp /srv/legion/logs/vllm

echo "=== Tuning host ==="
cat > /etc/sysctl.d/99-h200.conf << 'EOF'
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 3240000
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15
kernel.numa_balancing = 0
vm.nr_hugepages = 4096
vm.swappiness = 1
EOF
sysctl -p /etc/sysctl.d/99-h200.conf || true

echo never > /sys/kernel/mm/transparent_hugepage/defrag || true
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled || true
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$gov" 2>/dev/null || true
done

echo "=== Ensuring CUDA library path ==="
CUDA_PATH="$(find /usr/local -maxdepth 1 -name 'cuda-12*' -type d | sort -V | tail -1)"
if [ -n "$CUDA_PATH" ]; then
  echo "$CUDA_PATH/lib64" > /etc/ld.so.conf.d/cuda.conf
  ln -sfn "$CUDA_PATH" /usr/local/cuda
  ldconfig
fi

echo "=== Ensuring vLLM virtualenv ==="
if [ ! -d /data/vllm/env ]; then
  python3 -m venv /data/vllm/env
fi
source /data/vllm/env/bin/activate
TMPDIR=/data/tmp PIP_CACHE_DIR=/data/cache/pip pip install --upgrade pip
TMPDIR=/data/tmp PIP_CACHE_DIR=/data/cache/pip pip install vllm xxhash
deactivate

echo "=== Writing vLLM config ==="
cat > /data/vllm/config.yaml << EOF
model: ${MODEL_DIR}
dtype: bfloat16
tensor-parallel-size: 8
served-model-name: qwen3.6-27b
max-model-len: 131072
gpu-memory-utilization: 0.95
enable-prefix-caching: true
prefix-caching-hash-algo: xxhash
max-num-seqs: 128
max-num-batched-tokens: 131072
enable-chunked-prefill: true
scheduling-policy: fcfs
load-format: auto
safetensors-load-strategy: mmap
stream-interval: 1
reasoning-parser: deepseek_v3
enable-auto-tool-choice: true
tool-call-parser: hermes
host: 0.0.0.0
port: ${VLLM_PORT}
enable-server-load-tracking: true
enable-prompt-tokens-details: true
enable-log-requests: true
EOF

echo "=== Writing vLLM systemd service ==="
cat > /etc/systemd/system/vllm.service << 'EOF'
[Unit]
Description=vLLM Inference Server (8x H200 SXM)
After=network.target nvidia-persistenced.service nvidia-fabricmanager.service
Wants=nvidia-persistenced.service nvidia-fabricmanager.service

[Service]
Type=simple
User=vllm
Group=llm
Environment="PATH=/data/vllm/env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="TMPDIR=/data/tmp"
Environment="TORCHINDUCTOR_CACHE_DIR=/data/cache/torchinductor"
Environment="TRITON_CACHE_DIR=/data/cache/triton"
Environment="HF_HOME=/data/cache/huggingface"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64"
ExecStart=/data/vllm/env/bin/python -m vllm.entrypoints.openai.api_server --config /data/vllm/config.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
LimitMEMLOCK=infinity
StandardOutput=append:/srv/legion/logs/vllm/vllm.log
StandardError=append:/srv/legion/logs/vllm/vllm-error.log

[Install]
WantedBy=multi-user.target
EOF

echo "=== Starting/enabling services ==="
systemctl daemon-reload
systemctl enable docker ollama nomad consul nvidia-fabricmanager vllm
systemctl restart ollama
systemctl start nomad consul || true

if [ -d "$MODEL_DIR" ] && [ "$(find "$MODEL_DIR" -name '*.safetensors' 2>/dev/null | wc -l)" -gt 0 ]; then
  rm -f /dev/shm/psm_* /dev/shm/sem.mp-* /dev/shm/VLLM_* 2>/dev/null || true
  systemctl restart vllm
else
  echo "WARNING: no safetensors model found under $MODEL_DIR; vLLM service is enabled but not started."
fi

echo "=== Final GPU/Fabric check ==="
timeout 60 nvidia-smi
timeout 60 nvidia-smi topo -m || true
systemctl status nvidia-fabricmanager --no-pager -l

echo
echo "H200 setup resume complete."
