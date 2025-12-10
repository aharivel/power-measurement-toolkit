#!/bin/bash
#
# Lock CPU Frequency Script
# Forces all CPUs to a specific frequency by setting min=max
#
# Usage: sudo ./lock_cpu_freq.sh [800|2300]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# CPU frequency values (in kHz)
MIN_FREQ_KHZ=800000      # Minimum frequency
NOMINAL_FREQ_KHZ=2300000 # Nominal frequency

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [800|2300]

Locks CPU frequency by setting scaling_min_freq = scaling_max_freq.

Arguments:
    800      Lock all CPUs to 800 MHz
    2300     Lock all CPUs to 2300 MHz

This forces the CPU to stay at the specified frequency regardless of load.

Examples:
    sudo $SCRIPT_NAME 800     # Lock to 800 MHz
    sudo $SCRIPT_NAME 2300    # Lock to 2300 MHz
EOF
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

disable_turbo() {
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    fi

    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi
}

lock_frequency() {
    local target_freq=$1
    local freq_mhz=$((target_freq / 1000))

    echo "=========================================="
    echo "Locking all CPUs to ${freq_mhz} MHz"
    echo "=========================================="
    echo ""

    # Disable turbo
    disable_turbo

    # Count CPUs
    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
    echo "Found $cpu_count CPUs"
    echo ""

    local success_count=0
    local fail_count=0

    # Set frequency for all CPUs
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_num=$(basename "$cpu_dir" | sed 's/cpu//')
        cpufreq_dir="$cpu_dir/cpufreq"

        # Skip if CPU is offline
        if [ -f "$cpu_dir/online" ]; then
            online=$(cat "$cpu_dir/online" 2>/dev/null || echo "1")
            if [ "$online" != "1" ]; then
                continue
            fi
        fi

        # Skip if cpufreq not available
        if [ ! -d "$cpufreq_dir" ]; then
            ((fail_count++))
            continue
        fi

        # Set min and max to same value to lock frequency
        echo "$target_freq" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || {
            echo "  CPU$cpu_num: Failed to set min freq" >&2
            ((fail_count++))
            continue
        }

        echo "$target_freq" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || {
            echo "  CPU$cpu_num: Failed to set max freq" >&2
            ((fail_count++))
            continue
        }

        ((success_count++))
    done

    echo "Configuration complete:"
    echo "  ✓ Locked: $success_count CPUs"
    if [ $fail_count -gt 0 ]; then
        echo "  ✗ Failed: $fail_count CPUs" >&2
    fi
}

verify_frequency() {
    echo ""
    echo "=========================================="
    echo "Verifying Frequency Lock"
    echo "=========================================="
    echo ""

    # Wait for frequencies to settle
    sleep 2

    # Check sample CPUs
    local all_locked=true
    for cpu_num in 0 1 10 20 30 39; do
        cpufreq_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"

        if [ ! -d "$cpufreq_dir" ]; then
            continue
        fi

        min_freq=$(cat "$cpufreq_dir/scaling_min_freq" 2>/dev/null || echo "N/A")
        max_freq=$(cat "$cpufreq_dir/scaling_max_freq" 2>/dev/null || echo "N/A")
        cur_freq=$(cat "$cpufreq_dir/scaling_cur_freq" 2>/dev/null || echo "N/A")

        echo "CPU$cpu_num:"
        echo "  min_freq: $min_freq kHz"
        echo "  max_freq: $max_freq kHz"
        echo "  cur_freq: $cur_freq kHz"

        # Check if locked (min == max)
        if [ "$min_freq" != "$max_freq" ]; then
            echo "  ⚠ WARNING: Not locked (min != max)"
            all_locked=false
        elif [ "$cur_freq" != "N/A" ] && [ "$min_freq" != "N/A" ]; then
            # Allow small tolerance (within 50 MHz)
            diff=$((cur_freq - min_freq))
            if [ ${diff#-} -gt 50000 ]; then
                echo "  ⚠ WARNING: Current freq differs from target"
                all_locked=false
            else
                echo "  ✓ Locked correctly"
            fi
        fi
        echo ""
    done

    if [ "$all_locked" = true ]; then
        echo "✓ All CPUs successfully locked to target frequency"
    else
        echo "⚠ Some CPUs may not be locked correctly"
        echo ""
        echo "Run this command to check all CPUs:"
        echo "  grep . /sys/devices/system/cpu/cpu*/cpufreq/scaling_{min,max,cur}_freq"
    fi
}

main() {
    if [ $# -ne 1 ]; then
        usage
    fi

    check_root

    freq_arg=$1

    case "$freq_arg" in
        800)
            lock_frequency "$MIN_FREQ_KHZ"
            verify_frequency
            ;;
        2300)
            lock_frequency "$NOMINAL_FREQ_KHZ"
            verify_frequency
            ;;
        *)
            echo "ERROR: Invalid frequency '$freq_arg'" >&2
            echo "       Must be 800 or 2300" >&2
            echo ""
            usage
            ;;
    esac

    echo ""
    echo "=========================================="
    echo "Done!"
    echo "=========================================="
}

main "$@"
