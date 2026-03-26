#!/bin/bash
#
# Reset CPU Configuration to System Defaults
# Restores normal CPU frequency, C-states, and isolation settings
#
# Usage: sudo ./reset_to_defaults.sh
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [--force]

Reset CPU configuration to system defaults.

This script will:
  1. Restore default frequency governor (schedutil or performance)
  2. Enable all C-states
  3. Remove CPU isolation (restore normal scheduling)
  4. Enable turbo boost

Options:
    --force     Skip confirmation prompt

Examples:
    sudo $SCRIPT_NAME           # Reset with confirmation
    sudo $SCRIPT_NAME --force   # Reset without confirmation

Notes:
    - Must run as root (sudo)
    - Changes take effect immediately
    - Settings persist until next configuration or reboot
EOF
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

confirm_reset() {
    local force=$1

    if [ "$force" = true ]; then
        return 0
    fi

    echo "This will reset CPU configuration to defaults:"
    echo "  - Frequency governor: schedutil (or performance)"
    echo "  - Frequency limits: 800 MHz - 3400 MHz (dynamic)"
    echo "  - Turbo boost: enabled"
    echo "  - C-states: all enabled"
    echo "  - CPU isolation: removed"
    echo ""
    read -p "Continue? (y/N): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Reset cancelled"
        exit 0
    fi
}

reset_turbo() {
    echo "Enabling Intel Turbo Boost..."

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
        echo "  ✓ Turbo enabled"
    else
        echo "  ! intel_pstate/no_turbo not found"
    fi
}

reset_frequency() {
    echo ""
    echo "Restoring default frequency settings..."

    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    local success_count=0

    # Determine default governor (prefer schedutil, fallback to performance)
    local default_governor="schedutil"
    if ! grep -q "$default_governor" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null; then
        default_governor="performance"
    fi

    echo "  Using governor: $default_governor"

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_num=$(basename "$cpu_dir" | sed 's/cpu//')

        # Check if CPU is online
        if [ -f "$cpu_dir/online" ]; then
            online=$(cat "$cpu_dir/online")
            if [ "$online" != "1" ]; then
                continue
            fi
        fi

        cpufreq_dir="$cpu_dir/cpufreq"

        if [ ! -d "$cpufreq_dir" ]; then
            continue
        fi

        # Set governor
        if [ -f "$cpufreq_dir/scaling_governor" ]; then
            echo "$default_governor" > "$cpufreq_dir/scaling_governor" 2>/dev/null || true
        fi

        # Restore min/max to hardware limits
        if [ -f "$cpufreq_dir/cpuinfo_min_freq" ] && [ -f "$cpufreq_dir/cpuinfo_max_freq" ]; then
            hw_min=$(cat "$cpufreq_dir/cpuinfo_min_freq")
            hw_max=$(cat "$cpufreq_dir/cpuinfo_max_freq")

            echo "$hw_min" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || true
            echo "$hw_max" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || true
        fi

        ((success_count++))
    done

    echo "  ✓ Configured $success_count CPUs with $default_governor governor"
}

reset_cstates() {
    echo ""
    echo "Enabling all C-states..."

    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    local success_count=0

    for cpu_num in $(seq 0 $((cpu_count - 1))); do
        cpuidle_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpuidle"

        if [ ! -d "$cpuidle_dir" ]; then
            continue
        fi

        # Enable all states
        for state_dir in "$cpuidle_dir"/state*; do
            if [ -f "$state_dir/disable" ]; then
                echo 0 > "$state_dir/disable" 2>/dev/null || true
            fi
        done

        ((success_count++))
    done

    echo "  ✓ Enabled all C-states for $success_count CPUs"
}

reset_isolation() {
    echo ""
    echo "Removing CPU isolation..."

    if [ ! -d /sys/fs/cgroup/cpuset ]; then
        echo "  No cpuset configuration found"
        return 0
    fi

    # Move all tasks back to root cpuset
    if [ -d /sys/fs/cgroup/cpuset/housekeeping ]; then
        while read -r pid; do
            echo "$pid" > /sys/fs/cgroup/cpuset/tasks 2>/dev/null || true
        done < /sys/fs/cgroup/cpuset/housekeeping/tasks
    fi

    if [ -d /sys/fs/cgroup/cpuset/isolated ]; then
        while read -r pid; do
            echo "$pid" > /sys/fs/cgroup/cpuset/tasks 2>/dev/null || true
        done < /sys/fs/cgroup/cpuset/isolated/tasks
    fi

    # Remove cpuset directories
    rmdir /sys/fs/cgroup/cpuset/housekeeping 2>/dev/null || true
    rmdir /sys/fs/cgroup/cpuset/isolated 2>/dev/null || true

    echo "  ✓ CPU isolation removed"
}

verify_reset() {
    echo ""
    echo "Verifying reset..."
    echo ""

    # Check governor
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    echo "  Governor: $governor"

    # Check frequency range
    min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "N/A")
    max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "N/A")
    echo "  Frequency range: $min_freq - $max_freq kHz"

    # Check turbo
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" = "0" ]; then
            echo "  Turbo: enabled"
        else
            echo "  Turbo: disabled"
        fi
    fi

    # Check C-states
    enabled_count=0
    for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        if [ -f "$state_dir/disable" ]; then
            disabled=$(cat "$state_dir/disable")
            if [ "$disabled" = "0" ]; then
                ((enabled_count++))
            fi
        fi
    done
    echo "  C-states enabled: $enabled_count"
}

main() {
    local force=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                echo "ERROR: Unknown option '$1'" >&2
                usage
                ;;
        esac
    done

    check_root

    echo "========================================"
    echo "Reset CPU Configuration to Defaults"
    echo "========================================"
    echo ""

    confirm_reset "$force"

    echo ""
    echo "Resetting configuration..."
    echo ""

    reset_turbo
    reset_frequency
    reset_cstates
    reset_isolation

    verify_reset

    echo ""
    echo "========================================"
    echo "✓ Configuration reset complete"
    echo "========================================"
    echo ""
    echo "System restored to defaults."
    echo "Run './verify_config.sh' to verify current configuration."
}

main "$@"
