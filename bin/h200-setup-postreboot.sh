#!/bin/bash
set -euo pipefail

# DGX/HGX H200 SXM 8-GPU Setup Script (Post-Reboot)
# Run as root after reboot: su - then bash h200-setup-postreboot.sh
# Requires: h200-setup-prereboot.sh completed + reboot done

echo "=== Verifying root ==="
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (su -)"
  exit 1
fi

echo "=== Verifying H200 PCI BAR recovery settings ==="
if ! grep -qw 'pci=realloc=off' /proc/cmdline; then
  echo "ERROR: pci=realloc=off is not active. Refusing to continue because Linux may zero H200 BARs."
  echo "Current cmdline: $(cat /proc/cmdline)"
  echo "Expected grub setting: GRUB_CMDLINE_LINUX_DEFAULT=\"quiet pci=realloc=off\""
  exit 1
fi

for bdf in 04 14 64 77 84 94 e9 f6; do
  resource="/sys/bus/pci/devices/0000:${bdf}:00.0/resource"
  if [ ! -r "$resource" ]; then
    echo "ERROR: GPU 0000:${bdf}:00.0 is missing from sysfs."
    exit 1
  fi

  if awk 'NR==1||NR==3||NR==5 { if ($1 == "0x0000000000000000") bad = 1 } END { exit bad }' "$resource"; then
    :
  else
    echo "ERROR: GPU 0000:${bdf}:00.0 has an unassigned BAR."
    awk 'NR==1||NR==3||NR==5{print}' "$resource"
    exit 1
  fi
done

echo "=== Verifying NVMe mounts ==="
if ! mountpoint -q /data; then
  echo "ERROR: /data is not mounted. Check fstab."
  exit 1
fi
if ! mountpoint -q /srv/legion; then
  echo "ERROR: /srv/legion is not mounted. Check fstab."
  exit 1
fi

echo "=== Verifying NVIDIA driver ==="
if ! timeout 60 nvidia-smi; then
  echo "ERROR: nvidia-smi failed. Driver not loaded."
  echo "Check: dmesg | grep -i nvidia"
  echo "Try: apt install -y nvidia-open && reboot"
  exit 1
fi

GPU_COUNT=$(timeout 60 nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "Detected $GPU_COUNT GPUs"
if [ "$GPU_COUNT" -ne 8 ]; then
  echo "ERROR: Expected 8 H200 GPUs, found $GPU_COUNT"
  echo "Check: lspci | grep -i nvidia"
  exit 1
fi

echo "=== Starting nvidia-fabricmanager (NVSwitch required) ==="
systemctl start nvidia-fabricmanager
if ! systemctl status nvidia-fabricmanager --no-pager -l; then
  echo "ERROR: fabricmanager failed to start. NVSwitch won't work without it."
  echo "Check: journalctl -u nvidia-fabricmanager"
  exit 1
fi

echo "=== GPU persistence mode ==="
nvidia-smi -pm 1

echo "=== Verifying NVSwitch topology ==="
timeout 60 nvidia-smi topo -m
echo ""
echo "All GPUs should show NV18 (NVSwitch full mesh) connections."
echo ""
timeout 60 nvidia-smi nvlink -s

echo "=== CUDA library path ==="
CUDA_PATH=$(find /usr/local -maxdepth 1 -name "cuda-12*" -type d | sort -V | tail -1)
if [ -z "$CUDA_PATH" ]; then
  echo "WARNING: CUDA toolkit directory not found under /usr/local"
  CUDA_PATH="/usr/local/cuda-12.8"
fi
echo "$CUDA_PATH/lib64" > /etc/ld.so.conf.d/cuda.conf
ldconfig
ln -sf "$CUDA_PATH" /usr/local/cuda

echo "=== CPU performance governor ==="
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$gov" 2>/dev/null || true
done
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

echo "=== NUMA topology check ==="
numactl --hardware
echo ""
echo "For optimal GPU-CPU affinity, vLLM will use all NUMA nodes."

echo "=== Setting up Ollama ownership ==="
chown -R ollama:ollama /usr/share/ollama/.ollama
chown -R ollama:llm /srv/legion/ollama
chmod -R 775 /srv/legion/ollama

echo "=== Restarting Ollama ==="
systemctl restart ollama
sleep 2
systemctl status ollama --no-pager

echo "=== Installing vLLM ==="
if [ ! -d "/data/vllm/env" ]; then
  python3 -m venv /data/vllm/env
fi

mkdir -p /data/tmp /data/cache/pip
source /data/vllm/env/bin/activate
TMPDIR=/data/tmp PIP_CACHE_DIR=/data/cache/pip pip install vllm xxhash
deactivate

echo "=== Creating vLLM config ==="
cat > /data/vllm/config.yaml << 'EOF'
# Model (rsync from Apollo: rsync -avP root@10.11.164.93:/data/models/qwen3.6-27b/ /data/models/qwen3.6-27b/)
model: /data/models/qwen3.6-27b
dtype: bfloat16
tensor-parallel-size: 8
served-model-name: qwen3.6-27b

# Context & Memory — H200 141GB per card, 1.1TB total
max-model-len: 131072
gpu-memory-utilization: 0.95
enable-prefix-caching: true
prefix-caching-hash-algo: xxhash

# Scheduling & Batching — aggressive for 8x H200
max-num-seqs: 128
max-num-batched-tokens: 131072
enable-chunked-prefill: true
scheduling-policy: fcfs
performance-mode: throughput
async-scheduling: true

# Model Loading
load-format: auto
safetensors-load-strategy: mmap

# Streaming
stream-interval: 1

# Thinking/Reasoning
reasoning-parser: deepseek_v3

# Tool calling
enable-auto-tool-choice: true
tool-call-parser: hermes

# Server
host: 0.0.0.0
port: 8000

# Monitoring
enable-server-load-tracking: true
enable-prompt-tokens-details: true
enable-log-requests: true
kv-cache-metrics: true
enable-mfu-metrics: true
enable-logging-iteration-details: true
EOF

echo "=== Creating vLLM systemd service ==="
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

echo "=== Setting ownership ==="
chown -R vllm:llm /data/vllm /data/models /data/cache /data/tmp /srv/legion/logs/vllm

systemctl daemon-reload
systemctl enable vllm

echo "=== Checking for model files ==="
if [ -d "/data/models/qwen3.6-27b" ] && [ "$(find /data/models/qwen3.6-27b -name '*.safetensors' 2>/dev/null | wc -l)" -gt 0 ]; then
  echo "Model found at /data/models/qwen3.6-27b"
  echo "=== Starting vLLM ==="
  rm -f /dev/shm/psm_* /dev/shm/sem.mp-* /dev/shm/VLLM_*
  systemctl start vllm
  echo ""
  echo "vLLM is starting. First startup compiles CUDA graphs (~5-8 min on H200)."
  echo "Subsequent restarts load from cache (~20 sec)."
  echo "Monitor: journalctl -u vllm -f"
  echo "Logs: tail -f /srv/legion/logs/vllm/vllm.log"
else
  echo ""
  echo "WARNING: No model found at /data/models/qwen3.6-27b"
  echo ""
  echo "Rsync from Apollo V100 node:"
  echo "  rsync -aHAXx --numeric-ids --info=progress2 --partial --append-verify root@10.11.164.93:/data/models/qwen3.6-27b/ /data/models/qwen3.6-27b/"
  echo "  chown -R vllm:llm /data/models"
  echo "  systemctl start vllm"
fi

echo ""
echo "==========================================="
echo "  POST-REBOOT SETUP COMPLETE"
echo "==========================================="
echo ""
echo "  Hardware: 8x H200 SXM 141GB, NVSwitch full-mesh"
echo "  VRAM:     1.128 TB total"
echo "  RAM:      2.2 TiB"
echo ""
echo "  Services:"
echo "    Ollama:          http://0.0.0.0:11434 (embeddings)"
echo "    vLLM:            http://0.0.0.0:8000  (inference, TP=8, 131K context)"
echo "    fabricmanager:   active (NVSwitch)"
echo ""
echo "  vLLM config highlights:"
echo "    - TP=8 (all GPUs via NVSwitch, no DP needed for 27B)"
echo "    - 131K context (H200 has room to spare with 27B)"
echo "    - max-num-seqs=128, batched-tokens=131K"
echo "    - bfloat16 (native H200 dtype)"
echo ""
echo "  Test:"
echo "    curl http://localhost:8000/v1/models"
echo "    curl http://localhost:8000/v1/chat/completions \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"model\":\"qwen3.6-27b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":50,\"chat_template_kwargs\":{\"enable_thinking\":false}}'"
echo ""
echo "  For 235B later:"
echo "    - Update /data/vllm/config.yaml: model path, max-model-len, and batching limits"
echo "    - 235B at bf16 = ~470GB, fits easily in 1.1TB with room for KV cache"
echo ""
echo "  Useful commands:"
echo "    nvtop                                    # GPU monitoring"
echo "    nvidia-smi topo -m                       # NVSwitch topology"
echo "    tail -f /srv/legion/logs/vllm/vllm.log   # vLLM logs"
echo "    systemctl status nvidia-fabricmanager     # NVSwitch status"
echo "    systemctl status vllm                    # vLLM status"
echo "    systemctl status ollama                  # Ollama status"
echo "==========================================="
