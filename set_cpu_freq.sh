#!/bin/bash
#
# CPU Frequency Configuration Script
# Sets all CPUs to either nominal (max) or minimum frequency
#
# Usage: sudo ./set_cpu_freq.sh [nominal|min]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# CPU frequency values (in kHz) - from system_info
# Intel Xeon Silver 4316 @ 2.30GHz
MIN_FREQ_KHZ=800000      # Minimum frequency
NOMINAL_FREQ_KHZ=2300000 # Base/Nominal frequency (@ 2.30GHz)
MAX_FREQ_KHZ=3400000     # Maximum turbo frequency

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [nominal|min]

Sets CPU frequency for all CPUs.

Arguments:
    nominal     Set CPUs to nominal (base) frequency: ${NOMINAL_FREQ_KHZ} kHz (2300 MHz)
    min         Set CPUs to minimum frequency: ${MIN_FREQ_KHZ} kHz (800 MHz)

Requirements:
    - Must run as root (sudo)
    - Intel P-state driver or cpufreq interface available

Examples:
    sudo $SCRIPT_NAME nominal    # Set to 2300 MHz (base frequency)
    sudo $SCRIPT_NAME min        # Set to 800 MHz

Notes:
    - This script sets the same frequency for all CPUs
    - Uses the 'userspace' governor to pin frequency
    - Disables turbo boost for consistent measurements
    - Nominal = Base frequency (2300 MHz), NOT turbo/max (3400 MHz)
    - Changes persist until reboot or manual change
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
    echo "Disabling Intel Turbo Boost..."

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
        echo "  ✓ Turbo disabled via intel_pstate"
    else
        echo "  ! intel_pstate/no_turbo not found (may not be critical)"
    fi
}

set_frequency() {
    local target_freq=$1
    local mode_name=$2

    echo "Setting all CPUs to ${mode_name} frequency: ${target_freq} kHz"
    echo ""

    # Disable turbo first
    disable_turbo
    echo ""

    # Count CPUs
    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    echo "Configuring $cpu_count CPUs..."

    local success_count=0
    local fail_count=0

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_num=$(basename "$cpu_dir" | sed 's/cpu//')

        # Check if CPU is online
        if [ -f "$cpu_dir/online" ]; then
            online=$(cat "$cpu_dir/online")
            if [ "$online" != "1" ]; then
                echo "  CPU$cpu_num: skipped (offline)"
                continue
            fi
        fi

        cpufreq_dir="$cpu_dir/cpufreq"

        if [ ! -d "$cpufreq_dir" ]; then
            echo "  CPU$cpu_num: ERROR - cpufreq interface not found" >&2
            ((fail_count++))
            continue
        fi

        # Set governor to userspace for manual frequency control
        if [ -f "$cpufreq_dir/scaling_governor" ]; then
            echo "userspace" > "$cpufreq_dir/scaling_governor" 2>/dev/null || {
                echo "  CPU$cpu_num: WARNING - failed to set userspace governor" >&2
            }
        fi

        # Set the frequency
        if [ -f "$cpufreq_dir/scaling_setspeed" ]; then
            echo "$target_freq" > "$cpufreq_dir/scaling_setspeed" 2>/dev/null || {
                echo "  CPU$cpu_num: ERROR - failed to set frequency" >&2
                ((fail_count++))
                continue
            }
        else
            # Fallback: set min and max to same value
            echo "$target_freq" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || true
            echo "$target_freq" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || true
        fi

        ((success_count++))
    done

    echo ""
    echo "Configuration complete:"
    echo "  ✓ Success: $success_count CPUs"
    if [ $fail_count -gt 0 ]; then
        echo "  ✗ Failed: $fail_count CPUs" >&2
    fi
}

verify_frequency() {
    echo ""
    echo "Verifying frequency settings..."
    echo ""

    # Sample a few CPUs
    for cpu_num in 0 1 10 20 30; do
        cpufreq_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"

        if [ -d "$cpufreq_dir" ]; then
            governor=$(cat "$cpufreq_dir/scaling_governor" 2>/dev/null || echo "N/A")
            cur_freq=$(cat "$cpufreq_dir/scaling_cur_freq" 2>/dev/null || echo "N/A")

            echo "  CPU$cpu_num: governor=$governor, current_freq=$cur_freq kHz"
        fi
    done

    echo ""
    echo "For full verification, run: ./verify_config.sh"
}

main() {
    if [ $# -ne 1 ]; then
        usage
    fi

    check_root

    mode=$1

    case "$mode" in
        nominal|base)
            set_frequency "$NOMINAL_FREQ_KHZ" "nominal/base"
            verify_frequency
            echo ""
            echo "✓ All CPUs set to NOMINAL frequency (2300 MHz)"
            ;;
        min|minimum)
            set_frequency "$MIN_FREQ_KHZ" "minimum"
            verify_frequency
            echo ""
            echo "✓ All CPUs set to MINIMUM frequency (800 MHz)"
            ;;
        *)
            echo "ERROR: Invalid mode '$mode'" >&2
            echo ""
            usage
            ;;
    esac
}

main "$@"
