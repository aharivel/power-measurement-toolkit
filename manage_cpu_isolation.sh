#!/bin/bash
#
# CPU Isolation Management Script
# Help isolate CPUs for dedicated workloads (like DPDK)
#
# Usage: sudo ./manage_cpu_isolation.sh [command]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [command]

Manage CPU isolation for power measurement tests.

Commands:
    status              Show current CPU usage and process distribution
    topology            Display CPU topology (cores, threads)
    isolate CPUS        Move all movable tasks away from specified CPUs
    restore             Restore normal CPU scheduling (undo isolation)

Arguments:
    CPUS                CPU list in kernel format (e.g., "4-19,24-39")

Examples:
    # Show current status
    sudo $SCRIPT_NAME status

    # Show CPU topology
    sudo $SCRIPT_NAME topology

    # Isolate CPUs 4-39 (keep 0-3 for housekeeping)
    sudo $SCRIPT_NAME isolate 4-39

    # Restore normal scheduling
    sudo $SCRIPT_NAME restore

Notes:
    System has 40 CPUs (0-39):
    - CPU 0-19: Physical cores 0-19 (thread 0)
    - CPU 20-39: Physical cores 0-19 (thread 1)

    For isolation, typically use:
    - CPUs 0-3: Housekeeping (OS, monitoring tool)
    - CPUs 4-39: Isolated for workload

    This uses cpusets for isolation (doesn't require reboot).
    For persistent isolation across reboots, use kernel parameter:
      isolcpus=4-39
EOF
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

show_status() {
    echo "=== CPU Status and Load ==="
    echo ""

    echo "CPU Load (1-minute average):"
    uptime
    echo ""

    echo "Per-CPU usage (mpstat - last 1 second):"
    if command -v mpstat &>/dev/null; then
        mpstat -P ALL 1 1 | tail -n +4
    else
        echo "  mpstat not available (install: dnf install sysstat)"
    fi
    echo ""

    echo "IRQ Affinity Summary:"
    if [ -d /proc/irq ]; then
        echo "  Checking IRQ CPU affinity..."
        local total_irqs=0
        local irqs_on_all=0
        local irqs_limited=0

        for irq_dir in /proc/irq/[0-9]*; do
            if [ -f "$irq_dir/smp_affinity" ]; then
                ((total_irqs++))
                affinity=$(cat "$irq_dir/smp_affinity")
                # Check if all bits set (typically "ffffffffff" for 40 CPUs)
                if [[ "$affinity" =~ ^f+$ ]] || [ "$affinity" = "ffffffffff" ]; then
                    ((irqs_on_all++))
                else
                    ((irqs_limited++))
                fi
            fi
        done

        echo "  Total IRQs: $total_irqs"
        echo "  IRQs on all CPUs: $irqs_on_all"
        echo "  IRQs with limited affinity: $irqs_limited"
    fi
    echo ""

    echo "Cpuset configuration:"
    if [ -d /sys/fs/cgroup/cpuset ]; then
        if [ -f /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
            root_cpus=$(cat /sys/fs/cgroup/cpuset/cpuset.cpus)
            echo "  Root cpuset: $root_cpus"
        fi

        if [ -d /sys/fs/cgroup/cpuset/housekeeping ]; then
            hk_cpus=$(cat /sys/fs/cgroup/cpuset/housekeeping/cpuset.cpus)
            hk_tasks=$(cat /sys/fs/cgroup/cpuset/housekeeping/tasks | wc -l)
            echo "  Housekeeping cpuset: $hk_cpus ($hk_tasks tasks)"
        else
            echo "  No housekeeping cpuset configured"
        fi

        if [ -d /sys/fs/cgroup/cpuset/isolated ]; then
            iso_cpus=$(cat /sys/fs/cgroup/cpuset/isolated/cpuset.cpus)
            iso_tasks=$(cat /sys/fs/cgroup/cpuset/isolated/tasks | wc -l)
            echo "  Isolated cpuset: $iso_cpus ($iso_tasks tasks)"
        else
            echo "  No isolated cpuset configured"
        fi
    else
        echo "  cpuset cgroup not mounted or not available"
    fi
    echo ""

    echo "For detailed CPU topology, run: $SCRIPT_NAME topology"
}

show_topology() {
    echo "=== CPU Topology ==="
    echo ""

    lscpu --extended
    echo ""

    if command -v lstopo-no-graphics &>/dev/null; then
        echo "Detailed topology (lstopo):"
        lstopo-no-graphics --of console
    fi
    echo ""

    echo "CPU to Core mapping:"
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_num=$(basename "$cpu" | sed 's/cpu//')
        if [ -f "$cpu/topology/core_id" ]; then
            core_id=$(cat "$cpu/topology/core_id")
            thread_id=$(cat "$cpu/topology/thread_siblings_list" | cut -d',' -f1)
            printf "  CPU %-3s -> Core %-3s (thread siblings: %s)\n" \
                "$cpu_num" "$core_id" "$(cat $cpu/topology/thread_siblings_list)"
        fi
    done | head -20
    echo "  ... (showing first 20)"
}

setup_cpuset_cgroup() {
    # Ensure cpuset cgroup is available
    if [ ! -d /sys/fs/cgroup/cpuset ]; then
        echo "ERROR: cpuset cgroup not available" >&2
        echo "Try: mount -t cgroup -o cpuset cpuset /sys/fs/cgroup/cpuset" >&2
        return 1
    fi
}

isolate_cpus() {
    local isolated_cpus=$1

    echo "Isolating CPUs: $isolated_cpus"
    echo ""

    setup_cpuset_cgroup

    # Parse CPU list to determine housekeeping CPUs
    # For simplicity, assume housekeeping is 0-3 if isolating 4-39
    local housekeeping_cpus="0-3"

    echo "Creating cpuset hierarchy..."

    # Create housekeeping cpuset if it doesn't exist
    if [ ! -d /sys/fs/cgroup/cpuset/housekeeping ]; then
        mkdir -p /sys/fs/cgroup/cpuset/housekeeping
        echo "$housekeeping_cpus" > /sys/fs/cgroup/cpuset/housekeeping/cpuset.cpus
        echo "0" > /sys/fs/cgroup/cpuset/housekeeping/cpuset.mems
        echo "  ✓ Created housekeeping cpuset: $housekeeping_cpus"
    fi

    # Create isolated cpuset if it doesn't exist
    if [ ! -d /sys/fs/cgroup/cpuset/isolated ]; then
        mkdir -p /sys/fs/cgroup/cpuset/isolated
        echo "$isolated_cpus" > /sys/fs/cgroup/cpuset/isolated/cpuset.cpus
        echo "0" > /sys/fs/cgroup/cpuset/isolated/cpuset.mems
        echo "  ✓ Created isolated cpuset: $isolated_cpus"
    fi

    echo ""
    echo "Moving tasks to housekeeping CPUs..."

    # Move all tasks from root cpuset to housekeeping
    local moved_count=0
    local failed_count=0

    while read -r pid; do
        if [ -n "$pid" ] && [ "$pid" != "0" ]; then
            if echo "$pid" > /sys/fs/cgroup/cpuset/housekeeping/tasks 2>/dev/null; then
                ((moved_count++))
            else
                ((failed_count++))
            fi
        fi
    done < /sys/fs/cgroup/cpuset/tasks

    echo "  ✓ Moved $moved_count tasks to housekeeping CPUs"
    if [ $failed_count -gt 0 ]; then
        echo "  ! Failed to move $failed_count tasks (kernel threads are expected to fail)"
    fi

    echo ""
    echo "✓ CPU isolation configured"
    echo ""
    echo "Housekeeping CPUs: $housekeeping_cpus (OS and general processes)"
    echo "Isolated CPUs: $isolated_cpus (available for dedicated workload)"
    echo ""
    echo "To run a process on isolated CPUs, use:"
    echo "  taskset -c $isolated_cpus your_command"
    echo ""
    echo "Or move to cpuset:"
    echo "  echo \$PID > /sys/fs/cgroup/cpuset/isolated/tasks"
}

restore_isolation() {
    echo "Restoring normal CPU scheduling..."
    echo ""

    if [ ! -d /sys/fs/cgroup/cpuset ]; then
        echo "No cpuset configuration found"
        return 0
    fi

    # Move all tasks back to root cpuset
    if [ -d /sys/fs/cgroup/cpuset/housekeeping ]; then
        echo "Moving tasks from housekeeping to root..."
        while read -r pid; do
            echo "$pid" > /sys/fs/cgroup/cpuset/tasks 2>/dev/null || true
        done < /sys/fs/cgroup/cpuset/housekeeping/tasks
    fi

    if [ -d /sys/fs/cgroup/cpuset/isolated ]; then
        echo "Moving tasks from isolated to root..."
        while read -r pid; do
            echo "$pid" > /sys/fs/cgroup/cpuset/tasks 2>/dev/null || true
        done < /sys/fs/cgroup/cpuset/isolated/tasks
    fi

    # Remove cpuset directories
    rmdir /sys/fs/cgroup/cpuset/housekeeping 2>/dev/null || true
    rmdir /sys/fs/cgroup/cpuset/isolated 2>/dev/null || true

    echo ""
    echo "✓ CPU isolation removed - normal scheduling restored"
}

main() {
    if [ $# -lt 1 ]; then
        usage
    fi

    command=$1

    case "$command" in
        status)
            show_status
            ;;
        topology)
            show_topology
            ;;
        isolate)
            check_root
            if [ $# -ne 2 ]; then
                echo "ERROR: isolate requires CPU list argument" >&2
                echo "Example: $SCRIPT_NAME isolate 4-39" >&2
                exit 1
            fi
            isolate_cpus "$2"
            ;;
        restore)
            check_root
            restore_isolation
            ;;
        *)
            echo "ERROR: Unknown command '$command'" >&2
            echo ""
            usage
            ;;
    esac
}

main "$@"
