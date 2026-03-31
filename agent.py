#!/usr/bin/env python3
"""
Simulated eBPF Security Agent
==============================
Mimics how a real eBPF-based runtime sensor (like Wiz Runtime) allocates
per-CPU BPF maps on startup.  Each map is sized proportionally to the
number of online CPUs — a pattern that works fine in dev (2–4 cores) but
causes OOMKill in production (16+ cores) when container memory limits
are set based on dev-environment testing.
"""

import os
import sys
import time
import mmap
import signal

MAP_SIZE_PER_CPU_MB = 50  # Each "BPF map" allocates ~50 MB per CPU
NUM_MAPS = 3              # syscall_events, network_flows, file_access
POLL_INTERVAL = 2         # Seconds between simulated event processing

allocations = []


def get_cpu_count():
    """Return online CPU count (same as what BPF would see)."""
    return os.cpu_count() or 1


def allocate_bpf_maps(cpu_count):
    """
    Simulate BPF map allocation via mmap.
    Real eBPF maps use kernel memory, but for this simulation we use
    anonymous mmap to trigger the same cgroup OOM behaviour.
    """
    map_names = ["syscall_events", "network_flows", "file_access"]
    bytes_per_cpu = MAP_SIZE_PER_CPU_MB * 1024 * 1024

    for map_name in map_names[:NUM_MAPS]:
        size = bytes_per_cpu * cpu_count
        size_mb = size / (1024 * 1024)
        print(f"[agent] Allocating BPF map '{map_name}': "
              f"{cpu_count} CPUs x {MAP_SIZE_PER_CPU_MB}MB = {size_mb:.0f}MB")
        sys.stdout.flush()

        # mmap anonymous memory — this is what triggers cgroup OOM
        block = mmap.mmap(-1, size, mmap.MAP_ANONYMOUS | mmap.MAP_PRIVATE)

        # Touch pages to force physical allocation (not just virtual)
        print(f"[agent] Populating '{map_name}' pages...")
        sys.stdout.flush()
        for offset in range(0, size, 4096):
            block[offset] = 0xFF

        allocations.append(block)
        print(f"[agent] Map '{map_name}' ready.")
        sys.stdout.flush()


def event_loop():
    """Simulate the agent's main event processing loop."""
    cycle = 0
    while True:
        cycle += 1
        print(f"[agent] Processing events... (cycle {cycle})")
        sys.stdout.flush()
        time.sleep(POLL_INTERVAL)


def main():
    cpu_count = get_cpu_count()
    total_mb = MAP_SIZE_PER_CPU_MB * NUM_MAPS * cpu_count
    print(f"[agent] eBPF Security Agent starting")
    print(f"[agent] Detected {cpu_count} CPUs")
    print(f"[agent] Estimated memory requirement: {total_mb}MB")
    print(f"[agent] ---")
    sys.stdout.flush()

    try:
        allocate_bpf_maps(cpu_count)
        print(f"[agent] All maps allocated. Entering event loop.")
        sys.stdout.flush()
        event_loop()
    except MemoryError:
        print(f"[agent] FATAL: MemoryError during map allocation!", file=sys.stderr)
        sys.exit(137)
    except KeyboardInterrupt:
        print(f"\n[agent] Shutting down.")
        sys.exit(0)


if __name__ == "__main__":
    main()
