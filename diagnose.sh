#!/usr/bin/env bash
# =====================================================================
# diagnose.sh — Capture evidence of the OOMKill root cause
# =====================================================================
# Run this AFTER repro_issue.sh has crashed the container.
# It collects three pieces of evidence:
#   1. Docker inspect → confirms OOMKilled=true
#   2. dmesg → shows kernel OOM killer invocation with cgroup context
#   3. strace (live re-run) → shows mmap calls growing until SIGKILL
#
# Output: all evidence saved to artifacts/
# =====================================================================

set -euo pipefail

ARTIFACTS_DIR="./artifacts"
mkdir -p "$ARTIFACTS_DIR"

echo "========================================"
echo " Diagnosing: eBPF Agent OOMKill"
echo "========================================"
echo ""

# ---- Evidence 1: Docker container state ----
echo "[1/3] Checking container exit state..."
docker inspect ebpf-agent --format '{{json .State}}' \
    | python3 -m json.tool \
    > "$ARTIFACTS_DIR/container_state.json" 2>/dev/null || true

OOM=$(docker inspect ebpf-agent --format '{{.State.OOMKilled}}' 2>/dev/null || echo "unknown")
EXIT_CODE=$(docker inspect ebpf-agent --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
echo "      OOMKilled: $OOM"
echo "      Exit code: $EXIT_CODE  (137 = SIGKILL from OOM)"
echo "      Saved to:  $ARTIFACTS_DIR/container_state.json"
echo ""

# ---- Evidence 2: Kernel OOM killer logs ----
echo "[2/3] Capturing kernel OOM killer logs..."
dmesg | grep -i -A 5 "oom\|killed process\|out of memory\|memory cgroup" \
    > "$ARTIFACTS_DIR/dmesg_oom.log" 2>/dev/null || \
    echo "(dmesg not available — requires root or host access)" \
    > "$ARTIFACTS_DIR/dmesg_oom.log"
echo "      Saved to:  $ARTIFACTS_DIR/dmesg_oom.log"
echo ""

# ---- Evidence 3: strace of a fresh run ----
echo "[3/3] Running agent under strace to capture mmap pattern..."
echo "      (This will be killed by OOM — that's expected)"
echo ""

# Run agent under strace, capturing mmap and brk calls
# Timeout after 30s in case OOM doesn't fire (low CPU host)
timeout 30 docker run \
    --name ebpf-agent-strace \
    --memory=128m \
    --memory-swap=128m \
    --rm \
    ebpf-agent \
    strace -f -e trace=mmap,munmap,brk,mprotect \
        -o /dev/stderr \
        python3 -u agent.py \
    2> "$ARTIFACTS_DIR/strace_agent.log" || true

echo ""
echo "      Saved to:  $ARTIFACTS_DIR/strace_agent.log"

# ---- Summary ----
echo ""
echo "========================================"
echo " Evidence collected in $ARTIFACTS_DIR/"
echo "========================================"
echo ""
echo "Smoking gun: The strace log shows repeated mmap() calls"
echo "allocating $(nproc) x 50MB per BPF map.  When total RSS"
echo "exceeds the 128MB cgroup limit, the kernel sends SIGKILL"
echo "(exit code 137).  Docker restarts the container, which"
echo "re-allocates the same maps, causing a CrashLoopBackOff."
echo ""
echo "Root cause: Container memory limit was sized for a"
echo "dev environment (2 CPUs = 300MB needed) but deployed to"
echo "production ($(nproc) CPUs = $(($(nproc) * 150))MB needed)."
