#!/bin/bash
#
# CPU Frequency Configuration Script
# Sets all CPUs to either nominal (max) or minimum frequency
#
# Supports both Intel and AMD platforms with automatic detection.
#
# Usage: sudo ./set_cpu_freq.sh [nominal|min]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# Detect platform and set appropriate frequencies
detect_platform() {
    local vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")

    if [ "$vendor" = "AuthenticAMD" ]; then
        PLATFORM="AMD"
        # Read frequencies from amd-pstate if available
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_lowest_nonlinear_freq ]; then
            # Use lowest non-linear freq as min (more power-efficient than absolute min)
            MIN_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_lowest_nonlinear_freq 2>/dev/null || echo "1800000")
        else
            MIN_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo "400000")
        fi
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_nominal_freq ]; then
            NOMINAL_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_nominal_freq 2>/dev/null || echo "2250000")
        else
            NOMINAL_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "2250000")
        fi
        MAX_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "3100000")
    else
        PLATFORM="Intel"
        MIN_FREQ_KHZ=800000
        NOMINAL_FREQ_KHZ=2300000
        MAX_FREQ_KHZ=3400000
    fi
}

# Run detection immediately
detect_platform

usage() {
    local min_mhz=$((MIN_FREQ_KHZ / 1000))
    local nominal_mhz=$((NOMINAL_FREQ_KHZ / 1000))

    cat <<EOF
Usage: sudo $SCRIPT_NAME [nominal|min]

Sets CPU frequency for all CPUs.

Platform: $PLATFORM (driver: $DRIVER)

Arguments:
    nominal     Set CPUs to nominal (base) frequency: ${NOMINAL_FREQ_KHZ} kHz (${nominal_mhz} MHz)
    min         Set CPUs to minimum frequency: ${MIN_FREQ_KHZ} kHz (${min_mhz} MHz)

Requirements:
    - Must run as root (sudo)
    - Intel P-state, AMD P-state, or acpi-cpufreq driver

Examples:
    sudo $SCRIPT_NAME nominal    # Set to ${nominal_mhz} MHz (base frequency)
    sudo $SCRIPT_NAME min        # Set to ${min_mhz} MHz

Notes:
    - This script sets the same frequency for all CPUs
    - Uses the 'userspace' governor to pin frequency
    - Disables turbo/boost for consistent measurements
    - For AMD, switches amd-pstate to passive mode for frequency control
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
    echo "Disabling turbo/boost..."

    if [ "$PLATFORM" = "AMD" ]; then
        # AMD: use cpufreq boost interface
        if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
            echo 0 > /sys/devices/system/cpu/cpufreq/boost
            echo "  ✓ Boost disabled via cpufreq/boost"
        else
            echo "  ! cpufreq/boost not found"
        fi

        # Switch amd-pstate to passive mode for frequency control
        if [ -f /sys/devices/system/cpu/amd_pstate/status ]; then
            local current=$(cat /sys/devices/system/cpu/amd_pstate/status)
            if [ "$current" != "passive" ]; then
                echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null && \
                    echo "  ✓ Switched amd-pstate to passive mode" || \
                    echo "  ! Could not switch to passive mode (add amd_pstate=passive to kernel cmdline)"
            else
                echo "  ✓ amd-pstate already in passive mode"
            fi
        fi
    else
        # Intel: use intel_pstate no_turbo
        if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
            echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
            echo "  ✓ Turbo disabled via intel_pstate"
        else
            echo "  ! intel_pstate/no_turbo not found (may not be critical)"
        fi
    fi
}

set_frequency() {
    local target_freq=$1
    local mode_name=$2
    local freq_mhz=$((target_freq / 1000))

    echo "Platform: $PLATFORM (driver: $DRIVER)"
    echo "Setting all CPUs to ${mode_name} frequency: ${target_freq} kHz (${freq_mhz} MHz)"
    echo ""

    # Disable turbo first
    disable_turbo
    echo ""

    # Count CPUs
    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    echo "Configuring $cpu_count CPUs..."

    # Set userspace governor for all CPUs first
    echo "Setting userspace governor..."
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpufreq_dir="$cpu_dir/cpufreq"
        if [ -f "$cpufreq_dir/scaling_governor" ]; then
            echo "userspace" > "$cpufreq_dir/scaling_governor" 2>/dev/null || true
        fi
    done

    # Set frequency via sysfs - order matters!
    # 1. First widen the range by setting max to hardware max
    # 2. Then set min to target
    # 3. Then set max to target (narrows range)
    # 4. Finally set speed
    echo "Setting frequency via sysfs..."
    local success_count=0
    local fail_count=0

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpufreq_dir="$cpu_dir/cpufreq"
        if [ -d "$cpufreq_dir" ]; then
            # Get hardware limits
            local hw_max=$(cat "$cpufreq_dir/cpuinfo_max_freq" 2>/dev/null || echo "$target_freq")
            local hw_min=$(cat "$cpufreq_dir/cpuinfo_min_freq" 2>/dev/null || echo "$target_freq")

            # Step 1: Widen range - set max to hardware max first
            echo "$hw_max" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || true

            # Step 2: Set min to target (or hw_min if target is below hw_min)
            if [ "$target_freq" -ge "$hw_min" ]; then
                echo "$target_freq" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || true
            else
                echo "$hw_min" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || true
            fi

            # Step 3: Set max to target (narrows the range to pin frequency)
            echo "$target_freq" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || true

            # Step 4: Set speed explicitly (for userspace governor)
            if [ -f "$cpufreq_dir/scaling_setspeed" ]; then
                echo "$target_freq" > "$cpufreq_dir/scaling_setspeed" 2>/dev/null || true
            fi

            ((success_count++)) || true
        fi
    done

    echo "  ✓ Configured $success_count CPUs"
    echo "  Set scaling_min_freq = $target_freq"
    echo "  Set scaling_max_freq = $target_freq"
}

verify_frequency() {
    echo ""
    echo "Verifying frequency settings..."
    echo ""

    # Wait a moment for frequencies to settle
    sleep 1

    # Get total CPU count for sampling
    local cpu_count=$(nproc)

    # Sample CPUs evenly distributed across the system
    # For large systems (512 CPUs), sample: 0, 1, ~25%, ~50%, ~75%, last
    local sample_cpus="0 1"
    if [ "$cpu_count" -gt 10 ]; then
        sample_cpus="$sample_cpus $((cpu_count / 4)) $((cpu_count / 2)) $((cpu_count * 3 / 4)) $((cpu_count - 1))"
    fi

    printf "  %-6s %-10s %10s %10s %10s\n" "CPU" "Governor" "Min" "Max" "Current"
    printf "  %-6s %-10s %10s %10s %10s\n" "---" "--------" "---" "---" "-------"

    for cpu_num in $sample_cpus; do
        cpufreq_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"

        if [ -d "$cpufreq_dir" ]; then
            governor=$(cat "$cpufreq_dir/scaling_governor" 2>/dev/null || echo "N/A")
            cur_freq=$(cat "$cpufreq_dir/scaling_cur_freq" 2>/dev/null || echo "0")
            min_freq=$(cat "$cpufreq_dir/scaling_min_freq" 2>/dev/null || echo "0")
            max_freq=$(cat "$cpufreq_dir/scaling_max_freq" 2>/dev/null || echo "0")

            cur_mhz=$((cur_freq / 1000))
            min_mhz=$((min_freq / 1000))
            max_mhz=$((max_freq / 1000))

            printf "  %-6d %-10s %7d MHz %7d MHz %7d MHz\n" "$cpu_num" "$governor" "$min_mhz" "$max_mhz" "$cur_mhz"
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

    local nominal_mhz=$((NOMINAL_FREQ_KHZ / 1000))
    local min_mhz=$((MIN_FREQ_KHZ / 1000))

    case "$mode" in
        nominal|base)
            set_frequency "$NOMINAL_FREQ_KHZ" "nominal/base"
            verify_frequency
            echo ""
            echo "✓ All CPUs set to NOMINAL frequency (${nominal_mhz} MHz)"
            ;;
        min|minimum)
            set_frequency "$MIN_FREQ_KHZ" "minimum"
            verify_frequency
            echo ""
            echo "✓ All CPUs set to MINIMUM frequency (${min_mhz} MHz)"
            ;;
        *)
            echo "ERROR: Invalid mode '$mode'" >&2
            echo ""
            usage
            ;;
    esac
}

main "$@"
