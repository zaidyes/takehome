#!/usr/bin/env bash
# =====================================================================
# repro_issue.sh — Reproduce the eBPF agent CrashLoopBackOff
# =====================================================================
# This script builds and launches the agent container with a memory
# limit that is too small for the host's CPU count.  The agent will
# be OOMKilled repeatedly, simulating a CrashLoopBackOff.
#
# Usage:  chmod +x repro_issue.sh && ./repro_issue.sh
# =====================================================================

set -euo pipefail

echo "========================================"
echo " Reproducing: eBPF Agent CrashLoopBackOff"
echo "========================================"
echo ""
echo "Host CPUs:      $(nproc)"
echo "Agent needs:    ~$(($(nproc) * 50 * 3))MB"
echo "Container limit: 128MB"
echo ""

# Build the image
echo "[*] Building agent container..."
docker build -t ebpf-agent . -q

# Clean up any previous run
docker rm -f ebpf-agent 2>/dev/null || true

# Run with tight memory limit
echo "[*] Starting agent with 128MB memory limit..."
echo "[*] Watch for OOMKill — the agent should crash within seconds."
echo ""

docker run \
    --name ebpf-agent \
    --memory=128m \
    --memory-swap=128m \
    --restart=on-failure:3 \
    ebpf-agent

# We won't reach here — the container will be killed.
# After 3 restarts, Docker stops retrying.
echo ""
echo "[!] Container exited. Check: docker inspect ebpf-agent | grep OOMKilled"
