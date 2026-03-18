#!/usr/bin/env bash
set -e

# Set CPU governor to performance for all vCPU-pinned cores (both NUMA nodes, CPUs 0-39)
echo "Setting CPU governor to performance (CPUs 0-39)..."
for cpu in $(seq 0 39); do
    echo performance > /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor
done

# Allow unlimited RT scheduling so SCHED_FIFO vCPU pinning actually applies
# (systemd cgroup v2 blocks RT by default; this lifts that limit)
echo "Enabling unlimited RT scheduling..."
sysctl kernel.sched_rt_runtime_us=-1

echo "Done. Ready to launch: sudo VEP_MODE=1 HUGEPAGES=1g ./launch.sh"
