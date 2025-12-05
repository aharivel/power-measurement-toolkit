#!/bin/bash
#
# Configuration Verification Script
# Verifies CPU frequency, C-states, and isolation settings
#
# Usage: ./verify_config.sh [--detailed]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
DETAILED=false

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--detailed]

Verify current CPU configuration for power measurement tests.

Options:
    --detailed, -d      Show detailed per-CPU information

Output:
    - CPU frequency settings (governor, min/max, current)
    - C-state configuration (enabled/disabled states)
    - Turbo boost status
    - CPU isolation status
    - Summary with warnings/issues

Examples:
    $SCRIPT_NAME              # Quick summary
    $SCRIPT_NAME --detailed   # Full per-CPU details
EOF
    exit 1
}

print_section() {
    local title=$1
    echo ""
    echo "=== $title ==="
    echo ""
}

check_turbo_status() {
    print_section "Turbo Boost Status"

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" = "1" ]; then
            echo "  ✓ Turbo Boost: DISABLED (good for consistent measurements)"
        else
            echo "  ! Turbo Boost: ENABLED (may cause frequency variation)"
        fi
    else
        echo "  ? Turbo status unknown (intel_pstate interface not found)"
    fi
}

check_frequency_config() {
    print_section "CPU Frequency Configuration"

    local cpu0_cpufreq="/sys/devices/system/cpu/cpu0/cpufreq"

    if [ ! -d "$cpu0_cpufreq" ]; then
        echo "  ERROR: cpufreq interface not found"
        return 1
    fi

    # Governor
    local governor=$(cat "$cpu0_cpufreq/scaling_governor")
    echo "  Governor: $governor"

    # Frequency limits
    local min_freq=$(cat "$cpu0_cpufreq/scaling_min_freq")
    local max_freq=$(cat "$cpu0_cpufreq/scaling_max_freq")
    local cur_freq=$(cat "$cpu0_cpufreq/scaling_cur_freq")

    echo "  Configured range: $min_freq - $max_freq kHz"
    echo "  Current frequency (CPU 0): $cur_freq kHz"

    # Check if frequency is pinned
    if [ "$min_freq" = "$max_freq" ]; then
        freq_mhz=$((min_freq / 1000))
        echo "  ✓ Frequency PINNED to: $freq_mhz MHz"
    else
        echo "  ! Frequency NOT pinned (min != max)"
    fi

    # Show frequency distribution if detailed
    if [ "$DETAILED" = true ]; then
        echo ""
        echo "  Per-CPU frequencies:"
        for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
            if [ -d "$cpu_dir" ]; then
                cpu_num=$(echo "$cpu_dir" | grep -o "cpu[0-9]*" | sed 's/cpu//')
                freq=$(cat "$cpu_dir/scaling_cur_freq")
                governor=$(cat "$cpu_dir/scaling_governor")
                printf "    CPU %-3s: %8s kHz (governor: %s)\n" "$cpu_num" "$freq" "$governor"
            fi
        done
    else
        # Show sample of frequencies
        echo ""
        echo "  Sample frequencies (CPUs 0, 10, 20, 30):"
        for cpu_num in 0 10 20 30; do
            cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
            if [ -d "$cpu_dir" ]; then
                freq=$(cat "$cpu_dir/scaling_cur_freq")
                printf "    CPU %-3s: %8s kHz\n" "$cpu_num" "$freq"
            fi
        done
    fi
}

check_cstate_config() {
    print_section "C-State Configuration"

    local cpuidle_dir="/sys/devices/system/cpu/cpu0/cpuidle"

    if [ ! -d "$cpuidle_dir" ]; then
        echo "  ERROR: cpuidle interface not found"
        return 1
    fi

    echo "  C-states for CPU 0:"
    echo ""

    local enabled_states=()
    local disabled_states=()

    for state_dir in "$cpuidle_dir"/state*; do
        if [ -d "$state_dir" ]; then
            state=$(basename "$state_dir")
            name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
            desc=$(cat "$state_dir/desc" 2>/dev/null || echo "N/A")
            latency=$(cat "$state_dir/latency" 2>/dev/null || echo "N/A")
            disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")

            if [ "$disabled" = "0" ]; then
                status="✓ ENABLED "
                enabled_states+=("$name")
            else
                status="✗ DISABLED"
                disabled_states+=("$name")
            fi

            printf "    %-8s %-6s [%s]  latency: %4s us\n" "$state" "$name" "$status" "$latency"
        fi
    done

    echo ""
    echo "  Summary:"
    echo "    Enabled: ${enabled_states[*]}"
    if [ ${#disabled_states[@]} -gt 0 ]; then
        echo "    Disabled: ${disabled_states[*]}"
    fi

    # Provide test guidance
    echo ""
    if [[ " ${enabled_states[@]} " =~ " C6 " ]]; then
        echo "  → Configuration suitable for Test 1 (C6 deep sleep)"
    elif [[ ! " ${enabled_states[@]} " =~ " C6 " ]] && [[ " ${enabled_states[@]} " =~ " C1 " ]]; then
        echo "  → Configuration suitable for Test 2 (C1 shallow sleep)"
    fi
}

check_isolation_status() {
    print_section "CPU Isolation Status"

    if [ -d /sys/fs/cgroup/cpuset/housekeeping ]; then
        hk_cpus=$(cat /sys/fs/cgroup/cpuset/housekeeping/cpuset.cpus)
        hk_tasks=$(cat /sys/fs/cgroup/cpuset/housekeeping/tasks | wc -l)
        echo "  ✓ Housekeeping cpuset: $hk_cpus ($hk_tasks tasks)"
    else
        echo "  No housekeeping cpuset"
    fi

    if [ -d /sys/fs/cgroup/cpuset/isolated ]; then
        iso_cpus=$(cat /sys/fs/cgroup/cpuset/isolated/cpuset.cpus)
        iso_tasks=$(cat /sys/fs/cgroup/cpuset/isolated/tasks | wc -l)
        echo "  ✓ Isolated cpuset: $iso_cpus ($iso_tasks tasks)"
    else
        echo "  No isolated cpuset"
    fi

    # Check kernel isolcpus parameter
    if grep -q "isolcpus=" /proc/cmdline; then
        isolcpus=$(grep -o "isolcpus=[^ ]*" /proc/cmdline)
        echo "  Kernel parameter: $isolcpus"
    else
        echo "  No kernel isolcpus parameter"
    fi
}

check_power_interfaces() {
    print_section "Power Measurement Interfaces"

    # Check RAPL
    if [ -f /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj ]; then
        echo "  ✓ RAPL: Available"
        energy=$(cat /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj)
        echo "    Current energy counter: $energy uJ"
    else
        echo "  ✗ RAPL: NOT available"
    fi

    # Check IPMI
    if command -v ipmitool &>/dev/null; then
        echo "  ✓ ipmitool: Installed"
        # Try to read power (don't fail if it doesn't work)
        if sudo ipmitool dcmi power reading &>/dev/null; then
            power=$(sudo ipmitool dcmi power reading | grep "Instantaneous power reading" | awk '{print $4}')
            echo "    Current power reading: $power W"
        else
            echo "    ! IPMI command failed (check BMC configuration)"
        fi
    else
        echo "  ✗ ipmitool: NOT installed"
    fi
}

generate_summary() {
    print_section "Configuration Summary"

    local issues=()
    local warnings=()

    # Check frequency pinning
    local min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "0")
    local max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0")

    if [ "$min_freq" = "$max_freq" ] && [ "$min_freq" != "0" ]; then
        freq_mhz=$((min_freq / 1000))
        echo "  ✓ CPU frequency pinned to $freq_mhz MHz"
    else
        warnings+=("CPU frequency not pinned (may vary during test)")
    fi

    # Check turbo
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" = "1" ]; then
            echo "  ✓ Turbo boost disabled"
        else
            warnings+=("Turbo boost enabled (may cause frequency variation)")
        fi
    fi

    # Check C-states
    if [ -f /sys/devices/system/cpu/cpu0/cpuidle/state3/disable ]; then
        c6_disabled=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state3/disable)
        if [ "$c6_disabled" = "0" ]; then
            echo "  ✓ C6 enabled (suitable for Test 1)"
        else
            echo "  ✓ C6 disabled (suitable for Test 2)"
        fi
    fi

    # Check power interfaces
    if [ -f /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj ]; then
        echo "  ✓ RAPL interface available"
    else
        issues+=("RAPL interface not available")
    fi

    if command -v ipmitool &>/dev/null; then
        echo "  ✓ ipmitool installed"
    else
        issues+=("ipmitool not installed")
    fi

    # Print warnings and issues
    if [ ${#warnings[@]} -gt 0 ]; then
        echo ""
        echo "  Warnings:"
        for warning in "${warnings[@]}"; do
            echo "    ⚠ $warning"
        done
    fi

    if [ ${#issues[@]} -gt 0 ]; then
        echo ""
        echo "  Issues:"
        for issue in "${issues[@]}"; do
            echo "    ✗ $issue"
        done
        return 1
    fi

    echo ""
    echo "  ✓ System ready for power measurement tests"
    return 0
}

main() {
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --detailed|-d)
                DETAILED=true
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

    echo "========================================"
    echo "CPU Configuration Verification"
    echo "========================================"

    check_turbo_status
    check_frequency_config
    check_cstate_config
    check_isolation_status
    check_power_interfaces
    generate_summary

    echo ""
    echo "========================================"
}

main "$@"
