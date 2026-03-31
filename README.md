# eBPF Security Agent: CrashLoopBackOff due to Cgroup OOMKill

## The Problem

A customer deployed an eBPF-based runtime security agent as a Kubernetes DaemonSet.
The agent ran fine in their staging cluster (4 CPUs per node) but entered a
**CrashLoopBackOff** on production nodes (8–64 CPUs).

The SRE team opened a P1 ticket: *"Your agent is crash-looping and generating
thousands of pod restart events, triggering our PagerDuty alerts."*

### Business Impact

- **Blind spot**: While crash-looping, the agent is not providing runtime
  security coverage — the customer's production workloads are unprotected.
- **Noisy alerts**: Restart events flood the cluster's event stream, masking
  real incidents.
- **Resource waste**: Each restart cycle re-pulls the container image and
  re-initialises probes, consuming CPU and network bandwidth.
- **Customer trust**: A security product that destabilises production is worse
  than no security product at all.

## Root Cause

The agent allocates **per-CPU BPF maps** on startup. Each map uses ~50 MB per
online CPU. With 3 maps (syscall events, network flows, file access), total
memory scales linearly:

| CPUs | Memory Required | 128 MB Limit |
|------|-----------------|--------------|
| 2    | 364 MB          | Exceeded     |
| 4    | 664 MB          | Exceeded     |
| 8    | 1264 MB         | Exceeded     |
| 64   | 9664 MB         | Exceeded     |

The Kubernetes manifest set `resources.limits.memory: 128Mi` — a value that
was copy-pasted from a dev-environment manifest where the agent was tested on
a 2-CPU VM and happened to survive (barely).

When the agent starts, it calls `mmap()` to allocate each map. Linux satisfies
the virtual allocation immediately (overcommit), but as the agent **touches
the pages** to initialise them, the resident set size (RSS) grows. Once RSS
hits the cgroup memory ceiling (128 MB), the kernel's OOM killer sends
`SIGKILL` (exit code 137). Docker's `restart: on-failure` policy restarts
the container, which allocates the same maps again — CrashLoopBackOff.

## Diagnostic Methodology

### Step 1: Confirm the symptom

```bash
docker inspect ebpf-agent --format '{{.State.OOMKilled}}'
# → true

docker inspect ebpf-agent --format '{{.State.ExitCode}}'
# → 137 (SIGKILL)
```

Exit code 137 = 128 + 9 (SIGKILL). Combined with `OOMKilled: true`, this
confirms the kernel killed the process due to memory pressure, not an
application bug.

### Step 2: Check kernel logs for cgroup context

```bash
dmesg | grep -i "oom\|killed process\|memory cgroup"
```

Key line from `dmesg`:
```
memory cgroup out of memory: Killed process 48291 (python3)
  total-vm:823040kB, anon-rss:131072kB
  oom_memcg=/docker/a3f7c8e91b2d
```

This confirms:
- The OOM kill was **cgroup-scoped** (not system-wide).
- RSS reached 131072 kB ≈ 128 MB — exactly the container limit.
- The constraint was `CONSTRAINT_MEMCG`, meaning the cgroup limit, not
  host memory exhaustion.

### Step 3: Trace the allocation pattern with strace

```bash
strace -f -e trace=mmap,brk python3 agent.py
```

Key output:
```
mmap(NULL, 419430400, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
  = 0x7f3a0c000000
--- SIGKILL {si_signo=SIGKILL, si_code=SI_USER, si_pid=0, si_uid=0} ---
+++ killed by SIGKILL +++
```

The `mmap()` requests 400 MB (8 CPUs × 50 MB) in a single call.  Linux
allocates the virtual memory (overcommit allows this), but when the agent
touches the pages, physical memory grows until the cgroup OOM killer fires.

### Why These Tools

| Tool    | Purpose                                              |
|---------|------------------------------------------------------|
| `docker inspect` | Confirm OOMKilled flag and exit code — first triage step |
| `dmesg`  | Kernel-level evidence: which cgroup, which process, exact RSS at kill time |
| `strace` | Userspace evidence: the exact `mmap()` call size that triggered the issue |

These three tools together give a complete picture: **what** happened (docker),
**why** the kernel killed it (dmesg), and **what the process was doing** at
the time (strace).

## The Fix

### Immediate: Right-size the memory limit

```bash
./resolve_issue.sh
```

This calculates the correct limit using:
```
memory_limit = (CPU_COUNT × 50MB × NUM_MAPS) + 64MB headroom
```

### Long-term Recommendation

The agent should perform a **pre-flight memory check** on startup:

1. Read the cgroup memory limit from `/sys/fs/cgroup/memory.max`
2. Calculate required memory based on detected CPU count
3. If insufficient, **reduce the number of active maps** (graceful
   degradation) rather than allocating and crashing

This ensures the agent is resilient to misconfigured resource limits
instead of crash-looping.

## Repository Structure

```
├── README.md              ← This file
├── Dockerfile             ← Container image for the agent
├── docker-compose.yml     ← Runs agent with tight memory limit
├── agent.py               ← The simulated eBPF agent
├── repro_issue.sh         ← Reproduces the CrashLoopBackOff
├── diagnose.sh            ← Captures diagnostic evidence
├── resolve_issue.sh       ← Fixes the issue
└── artifacts/
    ├── container_state.json   ← docker inspect output (OOMKilled: true)
    ├── dmesg_oom.log          ← Kernel OOM killer logs
    └── strace_agent.log       ← mmap trace showing the smoking gun
```

## Reproducing

```bash
# 1. Break it
chmod +x repro_issue.sh && ./repro_issue.sh

# 2. Diagnose it
chmod +x diagnose.sh && ./diagnose.sh

# 3. Fix it
chmod +x resolve_issue.sh && ./resolve_issue.sh
```

Requires: Docker, bash, Python 3.11+ (inside container only).
