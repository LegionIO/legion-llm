#!/bin/bash
set -euo pipefail

# Apollo 6500 Gen10 - V100 SXM2 Setup Script (Post-Reboot)
# Run as root after reboot: su - then bash apollo-setup-postreboot.sh
# Requires: apollo-setup-prereboot.sh completed + reboot done

echo "=== Verifying root ==="
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Must run as root (su -)"
  exit 1
fi

echo "=== Verifying data drive ==="
if ! mountpoint -q /data; then
  echo "ERROR: /data is not mounted. Check fstab."
  exit 1
fi

echo "=== Checking nvidia-smi binary ==="
if ! command -v nvidia-smi &>/dev/null; then
  echo "nvidia-smi not found, extracting from .run installer..."
  wget -q https://us.download.nvidia.com/tesla/580.126.20/NVIDIA-Linux-x86_64-580.126.20.run -O /tmp/nvidia.run
  chmod +x /tmp/nvidia.run
  /tmp/nvidia.run --extract-only --target /tmp/nvidia-extract
  cp /tmp/nvidia-extract/nvidia-smi /usr/local/bin/
  chmod +x /usr/local/bin/nvidia-smi
  rm -rf /tmp/nvidia.run /tmp/nvidia-extract
fi

echo "=== Verifying NVIDIA driver ==="
nvidia-smi
if [ $? -ne 0 ]; then
  echo "ERROR: nvidia-smi failed. Driver not loaded."
  echo "Check: dmesg | grep -i nvidia"
  echo "If 595 driver loaded instead of 580, purge and reinstall:"
  echo "  apt remove -y --purge nvidia-kernel-dkms nvidia-driver"
  echo "  apt install -y nvidia-driver=580.126.20-1 nvidia-kernel-dkms=580.126.20-1"
  echo "  reboot"
  exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "Detected $GPU_COUNT GPUs"
if [ "$GPU_COUNT" -ne 8 ]; then
  echo "WARNING: Expected 8 GPUs, found $GPU_COUNT"
fi

echo "=== GPU persistence mode + max clocks ==="
nvidia-smi -pm 1
nvidia-smi -ac 877,1530

echo "=== Verifying NVLink ==="
nvidia-smi topo -m
nvidia-smi nvlink -s

echo "=== Moving CUDA toolkit to /data (free root space) ==="
if [ -d "/usr/local/cuda-12.6" ] && [ ! -L "/usr/local/cuda-12.6" ]; then
  mv /usr/local/cuda-12.6 /data/cuda-12.6
  ln -sf /data/cuda-12.6 /usr/local/cuda-12.6
  rm -f /usr/local/cuda-12 /usr/local/cuda
  ln -sf /data/cuda-12.6 /usr/local/cuda-12
  ln -sf /data/cuda-12.6 /usr/local/cuda
fi

echo "=== Moving Ollama libs to /data (free root space) ==="
if [ -d "/usr/local/lib/ollama" ] && [ ! -L "/usr/local/lib/ollama" ]; then
  mv /usr/local/lib/ollama /data/ollama-lib
  ln -sf /data/ollama-lib /usr/local/lib/ollama
fi

echo "=== CUDA library path ==="
echo '/usr/local/cuda-12.6/lib64' > /etc/ld.so.conf.d/cuda.conf
ldconfig

echo "=== CPU performance tuning ==="
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$gov" 2>/dev/null || true
done
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

echo "=== Setting up Ollama ownership ==="
chown -R ollama:ollama /usr/share/ollama/.ollama
chown -R ollama:llm /srv/ollama
chmod -R 775 /srv/ollama

echo "=== Restarting Ollama ==="
systemctl restart ollama
sleep 2
systemctl status ollama --no-pager

echo "=== Installing vLLM ==="
apt install -y python3-pip python3-venv

if [ ! -d "/data/vllm/env" ]; then
  python3 -m venv /data/vllm/env
fi

mkdir -p /data/tmp /data/cache/pip
source /data/vllm/env/bin/activate
TMPDIR=/data/tmp PIP_CACHE_DIR=/data/cache/pip pip install vllm xxhash
deactivate

echo "=== Creating vLLM config ==="
cat > /data/vllm/config.yaml << 'EOF'
# Model
model: /data/models/qwen3.6-27b
dtype: float16
tensor-parallel-size: 4
data-parallel-size: 2
served-model-name: qwen3.6-27b

# Context & Memory
max-model-len: 32768
gpu-memory-utilization: 0.95
enable-prefix-caching: true
prefix-caching-hash-algo: xxhash

# Scheduling & Batching
max-num-seqs: 128
max-num-batched-tokens: 65536
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
Description=vLLM Inference Server
After=network.target nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=simple
User=vllm
Group=llm
Environment="PATH=/data/vllm/env/bin:/usr/local/bin:/usr/bin:/bin"
Environment="TMPDIR=/data/tmp"
Environment="TORCHINDUCTOR_CACHE_DIR=/data/cache/torchinductor"
Environment="TRITON_CACHE_DIR=/data/cache/triton"
ExecStart=/data/vllm/env/bin/python -m vllm.entrypoints.openai.api_server --config /data/vllm/config.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
LimitMEMLOCK=infinity
StandardOutput=append:/var/log/vllm/vllm.log
StandardError=append:/var/log/vllm/vllm-error.log

[Install]
WantedBy=multi-user.target
EOF

echo "=== Setting ownership ==="
chown -R vllm:llm /data/vllm /data/models /data/cache /data/tmp /var/log/vllm

systemctl daemon-reload
systemctl enable vllm

echo "=== Checking for model files ==="
if [ -d "/data/models/qwen3.6-27b" ] && [ "$(ls /data/models/qwen3.6-27b/*.safetensors 2>/dev/null | wc -l)" -gt 0 ]; then
  echo "Model found at /data/models/qwen3.6-27b"
  echo "=== Starting vLLM ==="
  rm -f /dev/shm/psm_* /dev/shm/sem.mp-* /dev/shm/VLLM_*
  systemctl start vllm
  echo ""
  echo "vLLM is starting. First startup compiles CUDA graphs (~8-10 min)."
  echo "Subsequent restarts load from cache (~30 sec)."
  echo "Monitor: journalctl -u vllm -f"
  echo "Logs: tail -f /var/log/vllm/vllm.log /var/log/vllm/vllm-error.log"
else
  echo ""
  echo "WARNING: No model found at /data/models/qwen3.6-27b"
  echo "You need to rsync the model from another machine:"
  echo "  rsync -avP /path/to/qwen3.6-27b/ miverso2@\$(hostname -I | awk '{print \$1}'):/data/models/qwen3.6-27b/"
  echo "  chown -R vllm:llm /data/models"
  echo "  systemctl start vllm"
fi

echo ""
echo "==========================================="
echo "  POST-REBOOT SETUP COMPLETE"
echo "==========================================="
echo ""
echo "  Services:"
echo "    Ollama:  http://0.0.0.0:11434 (embeddings)"
echo "    vLLM:    http://0.0.0.0:8000  (inference, DP=2, TP=4, all 8 GPUs)"
echo ""
echo "  Test:"
echo "    curl http://localhost:8000/v1/models"
echo "    curl http://localhost:8000/v1/chat/completions \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"model\":\"qwen3.6-27b\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":50,\"chat_template_kwargs\":{\"enable_thinking\":false}}'"
echo ""
echo "  Useful commands:"
echo "    nvtop                          # GPU monitoring"
echo "    nvidia-smi topo -m             # NVLink topology"
echo "    tail -f /var/log/vllm/vllm.log # vLLM logs"
echo "    systemctl status vllm          # vLLM status"
echo "    systemctl status ollama        # Ollama status"
echo "==========================================="
