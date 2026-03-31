#!/usr/bin/env bash
# =====================================================================
# resolve_issue.sh — Fix the eBPF agent OOMKill / CrashLoopBackOff
# =====================================================================
# Two-part fix:
#   1. IMMEDIATE: Right-size the container memory limit based on
#      actual host CPU count.
#   2. LONG-TERM: Set an environment variable that tells the agent
#      to cap its map count if memory is constrained.
#
# Usage:  chmod +x resolve_issue.sh && ./resolve_issue.sh
# =====================================================================

set -euo pipefail

echo "========================================"
echo " Resolving: eBPF Agent CrashLoopBackOff"
echo "========================================"
echo ""

CPU_COUNT=$(nproc)
# Formula: 50MB per CPU * 3 maps + 64MB headroom for Python runtime
REQUIRED_MB=$(( (CPU_COUNT * 50 * 3) + 64 ))

echo "Host CPUs:        $CPU_COUNT"
echo "Calculated need:  ${REQUIRED_MB}MB"
echo ""

# ---- Step 1: Stop the crash-looping container ----
echo "[1/3] Stopping crash-looping container..."
docker rm -f ebpf-agent 2>/dev/null || true
echo "      Done."
echo ""

# ---- Step 2: Restart with correct memory limit ----
echo "[2/3] Restarting agent with ${REQUIRED_MB}MB limit..."
docker run -d \
    --name ebpf-agent \
    --memory="${REQUIRED_MB}m" \
    --memory-swap="${REQUIRED_MB}m" \
    --restart=on-failure:3 \
    -e AGENT_MAX_MAPS=3 \
    ebpf-agent

echo "      Container started."
echo ""

# ---- Step 3: Verify health ----
echo "[3/3] Verifying agent is stable (waiting 10s)..."
sleep 10

STATUS=$(docker inspect ebpf-agent --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
OOM=$(docker inspect ebpf-agent --format '{{.State.OOMKilled}}' 2>/dev/null || echo "unknown")
RESTARTS=$(docker inspect ebpf-agent --format '{{.RestartCount}}' 2>/dev/null || echo "unknown")

echo ""
echo "========================================"
echo " Verification"
echo "========================================"
echo "  Status:     $STATUS"
echo "  OOMKilled:  $OOM"
echo "  Restarts:   $RESTARTS"
echo ""

if [ "$STATUS" = "running" ] && [ "$OOM" = "false" ]; then
    echo "  [OK] Agent is healthy. Issue resolved."
    echo ""
    echo "  Recommended follow-up for the customer:"
    echo "  - Update K8s DaemonSet manifest to use the formula:"
    echo "    memory_limit = (CPU_COUNT * 50 * NUM_MAPS) + 64 MB"
    echo "  - Or set AGENT_MAX_MAPS=2 to reduce footprint on"
    echo "    memory-constrained nodes (trades coverage for stability)."
else
    echo "  [WARN] Agent may still be unstable. Check:"
    echo "    docker logs ebpf-agent"
    echo "    docker inspect ebpf-agent | grep -i oom"
fi
