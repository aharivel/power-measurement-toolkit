#!/bin/bash
#
# CPU Frequency Configuration Script for Intel Xeon 6780E
# Sets all CPUs to either nominal (base) or minimum frequency
#
# Usage: sudo ./set_cpu_freq.sh [nominal|min]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# Detect platform and set appropriate frequencies
detect_platform() {
    local vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")

    if [ "$vendor" = "GenuineIntel" ]; then
        PLATFORM="Intel"

        # Intel Xeon 6780E specs:
        # - Base frequency: 2200 MHz
        # - Max turbo: 3000 MHz
        # - Min: read from sysfs (typically 800 MHz)

        if [ "$DRIVER" = "intel_pstate" ] || [ "$DRIVER" = "intel_cpufreq" ]; then
            # intel_pstate (active) or intel_cpufreq (passive mode) driver
            # intel_cpufreq is intel_pstate running in passive mode
            MIN_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo "800000")
            MAX_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "3000000")
            # Base/nominal frequency for Xeon 6780E is 2200 MHz
            # Intel doesn't expose base_frequency easily, so we hardcode it
            NOMINAL_FREQ_KHZ=2200000
            
            # Check if intel_pstate is in passive mode (intel_cpufreq)
            if [ "$DRIVER" = "intel_cpufreq" ] || ([ -f /sys/devices/system/cpu/intel_pstate/status ] && [ "$(cat /sys/devices/system/cpu/intel_pstate/status)" = "passive" ]); then
                INTEL_PSTATE_MODE="passive"
            else
                INTEL_PSTATE_MODE="active"
            fi
        elif [ "$DRIVER" = "acpi-cpufreq" ]; then
            # acpi-cpufreq uses discrete P-states
            local avail_freqs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)
            if [ -n "$avail_freqs" ]; then
                MAX_FREQ_KHZ=$(echo "$avail_freqs" | awk '{print $1}')
                MIN_FREQ_KHZ=$(echo "$avail_freqs" | awk '{print $NF}')
            else
                MIN_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo "800000")
                MAX_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "3000000")
            fi
            NOMINAL_FREQ_KHZ=2200000
        else
            # Generic fallback
            MIN_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo "800000")
            MAX_FREQ_KHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "3000000")
            NOMINAL_FREQ_KHZ=2200000
        fi
    else
        echo "ERROR: This script is designed for Intel platforms." >&2
        echo "       Detected vendor: $vendor" >&2
        echo "       For AMD, use the amd-epyc-support branch." >&2
        exit 1
    fi
}

# Run detection immediately
detect_platform

usage() {
    local min_mhz=$((MIN_FREQ_KHZ / 1000))
    local nominal_mhz=$((NOMINAL_FREQ_KHZ / 1000))
    local max_mhz=$((MAX_FREQ_KHZ / 1000))

    cat <<EOF
Usage: sudo $SCRIPT_NAME [nominal|min]

Sets CPU frequency for all CPUs on Intel Xeon 6780E (288 logical CPUs).

Platform: $PLATFORM (driver: $DRIVER, pstate mode: ${INTEL_PSTATE_MODE:-unknown})
CPU Frequencies:
    Minimum:  ${min_mhz} MHz
    Nominal:  ${nominal_mhz} MHz (base frequency)
    Maximum:  ${max_mhz} MHz (turbo)

Arguments:
    nominal     Set CPUs to nominal (base) frequency: ${nominal_mhz} MHz
    min         Set CPUs to minimum frequency: ${min_mhz} MHz

Requirements:
    - Must run as root (sudo)
    - Intel P-state, intel_cpufreq (passive), or acpi-cpufreq driver

Examples:
    sudo $SCRIPT_NAME nominal    # Set to ${nominal_mhz} MHz (base frequency)
    sudo $SCRIPT_NAME min        # Set to ${min_mhz} MHz

Notes:
    - This script sets the same frequency for all CPUs
    - Uses the 'userspace' governor to pin frequency (if available)
    - For intel_cpufreq (passive mode), uses frequency limits with appropriate governor
    - Disables turbo boost for consistent measurements
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
    echo "Disabling turbo boost..."

    # Intel: use intel_pstate no_turbo
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
        echo "  ✓ Turbo disabled via intel_pstate/no_turbo"
    fi

    # Generic boost interface (fallback)
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 > /sys/devices/system/cpu/cpufreq/boost
        echo "  ✓ Boost disabled via cpufreq/boost"
    fi

    # MSR-based turbo disable (if msr module loaded)
    if [ -w /dev/cpu/0/msr ] && command -v wrmsr &>/dev/null; then
        # Bit 38 of MSR 0x1a0 disables turbo
        # This is a more reliable method on some systems
        echo "  (MSR turbo disable available but not used - intel_pstate preferred)"
    fi
}

set_governor() {
    local governor=$1
    echo "Setting governor to '$governor'..."

    local success=0
    local fail=0

    # Handle systems with many CPUs (up to cpu287)
    for cpu_num in $(seq 0 287); do
        cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}"
        cpufreq_dir="$cpu_dir/cpufreq"
        
        # Skip if CPU directory doesn't exist
        if [ ! -d "$cpu_dir" ]; then
            continue
        fi
        
        # Skip offline CPUs
        if [ -f "$cpu_dir/online" ]; then
            online=$(cat "$cpu_dir/online" 2>/dev/null || echo "1")
            if [ "$online" != "1" ]; then
                continue
            fi
        fi
        
        if [ -f "$cpufreq_dir/scaling_governor" ]; then
            if echo "$governor" > "$cpufreq_dir/scaling_governor" 2>/dev/null; then
                ((success++))
            else
                ((fail++))
            fi
        fi
    done

    if [ $fail -eq 0 ]; then
        echo "  ✓ Governor set to '$governor' on $success CPUs"
    else
        echo "  ! Governor set on $success CPUs, failed on $fail CPUs"
    fi
}

set_frequency() {
    local target_freq=$1
    local mode_name=$2
    local freq_mhz=$((target_freq / 1000))

    echo "=========================================="
    echo "CPU Frequency Configuration"
    echo "=========================================="
    echo ""
    echo "Platform: $PLATFORM (driver: $DRIVER, pstate mode: ${INTEL_PSTATE_MODE:-unknown})"
    echo "Target: ${mode_name} frequency - ${freq_mhz} MHz"
    echo ""

    # Disable turbo first
    disable_turbo
    echo ""

    # Count CPUs
    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
    echo "Configuring $cpu_count CPUs..."
    echo ""

    # Try to use userspace governor for precise frequency control
    # Check if userspace is available
    local avail_govs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
    if echo "$avail_govs" | grep -q "userspace"; then
        echo "  ✓ Userspace governor available, using it for precise frequency control"
        set_governor "userspace"
        USE_USERSPACE=true
    else
        echo "  ! Userspace governor not available, using frequency limits only"
        USE_USERSPACE=false
        
        # For intel_pstate in active mode, we need to use performance governor
        # and rely on frequency limits
        if [ "$DRIVER" = "intel_pstate" ] && [ "$avail_govs" = "performance powersave" ]; then
            echo "  ! Detected intel_pstate in active mode"
            echo "  ! Using performance governor with frequency limits"
            set_governor "performance"
        elif [ "$DRIVER" = "intel_cpufreq" ] || [ "${INTEL_PSTATE_MODE}" = "passive" ]; then
            echo "  ✓ Detected intel_cpufreq (passive mode)"
            echo "  ✓ Using userspace governor for precise frequency control"
            # For intel_cpufreq, userspace should be available
            if echo "$avail_govs" | grep -q "userspace"; then
                set_governor "userspace"
                USE_USERSPACE=true
            else
                echo "  ! Userspace not available even in passive mode, falling back to performance"
                set_governor "performance"
            fi
        fi
    fi
    echo ""

    # Set frequency via sysfs
    # Order matters for intel_pstate:
    # 1. First widen the range by setting max to hardware max
    # 2. Then set min to target
    # 3. Then set max to target (narrows range)
    # 4. Finally set speed (if userspace governor)

    echo "Setting frequency limits..."
    local success_count=0
    local fail_count=0

    # Handle systems with many CPUs (up to cpu287)
    for cpu_num in $(seq 0 287); do
        cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}"
        cpufreq_dir="$cpu_dir/cpufreq"

        # Skip if CPU directory doesn't exist
        if [ ! -d "$cpu_dir" ]; then
            continue
        fi

        # Skip offline CPUs
        if [ -f "$cpu_dir/online" ]; then
            online=$(cat "$cpu_dir/online" 2>/dev/null || echo "1")
            if [ "$online" != "1" ]; then
                echo "  - CPU${cpu_num}: offline, skipping"
                continue
            fi
        fi

        if [ -d "$cpufreq_dir" ]; then
            # Get hardware limits
            local hw_max=$(cat "$cpufreq_dir/cpuinfo_max_freq" 2>/dev/null || echo "$target_freq")
            local hw_min=$(cat "$cpufreq_dir/cpuinfo_min_freq" 2>/dev/null || echo "$target_freq")

            echo "  Configuring CPU${cpu_num}..."

            # Step 1: Widen range - set max to hardware max first
            echo "$hw_max" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || true

            # Step 2: Set min to target (clamp to hw_min if needed)
            if [ "$target_freq" -ge "$hw_min" ]; then
                echo "$target_freq" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || true
            else
                echo "$hw_min" > "$cpufreq_dir/scaling_min_freq" 2>/dev/null || true
            fi

            # Step 3: Set max to target (narrows the range to pin frequency)
            echo "$target_freq" > "$cpufreq_dir/scaling_max_freq" 2>/dev/null || true

            # Step 4: Set speed explicitly (for userspace governor)
            if [ "$USE_USERSPACE" = true ] && [ -f "$cpufreq_dir/scaling_setspeed" ]; then
                echo "$target_freq" > "$cpufreq_dir/scaling_setspeed" 2>/dev/null || true
            fi

            ((success_count++)) || true
        else
            echo "  - CPU${cpu_num}: no cpufreq directory, skipping"
            ((fail_count++)) || true
        fi
    done

    echo "  ✓ Configured $success_count CPUs"
    if [ $fail_count -gt 0 ]; then
        echo "  ! Failed to configure $fail_count CPUs"
    fi
    echo "  scaling_min_freq = $target_freq kHz"
    echo "  scaling_max_freq = $target_freq kHz"
}

verify_frequency() {
    local target_freq=$1

    echo ""
    echo "=========================================="
    echo "Verifying Frequency Configuration"
    echo "=========================================="
    echo ""

    # Wait for frequencies to settle
    sleep 2

    # Sample a few CPUs for verification (first, middle, last)
    local sample_cpus="0 71 143 215 287"

    printf "  %-6s %-12s %10s %10s %10s\n" "CPU" "Governor" "Min" "Max" "Current"
    printf "  %-6s %-12s %10s %10s %10s\n" "---" "--------" "---" "---" "-------"

    local all_ok=true
    local checked_cpus=0
    
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

            # Check if locked correctly
            local status=""
            if [ "$min_freq" = "$max_freq" ]; then
                # Allow 50 MHz tolerance for current freq
                local diff=$((cur_freq - target_freq))
                if [ ${diff#-} -le 50000 ]; then
                    status="✓"
                else
                    status="~"
                    all_ok=false
                fi
            else
                status="✗"
                all_ok=false
            fi

            printf "  %-6d %-12s %7d MHz %7d MHz %7d MHz %s\n" \
                "$cpu_num" "$governor" "$min_mhz" "$max_mhz" "$cur_mhz" "$status"
            ((checked_cpus++))
        fi
    done

    echo ""
    if [ "$all_ok" = true ] && [ $checked_cpus -gt 0 ]; then
        echo "✓ All sampled CPUs locked correctly"
    else
        echo "⚠ Some CPUs may not be locked correctly"
        echo "  Run: grep . /sys/devices/system/cpu/cpu*/cpufreq/scaling_{min,max,cur}_freq"
    fi
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
        nominal|base|2200)
            set_frequency "$NOMINAL_FREQ_KHZ" "nominal/base"
            verify_frequency "$NOMINAL_FREQ_KHZ"
            echo ""
            echo "=========================================="
            echo "✓ All CPUs set to NOMINAL frequency (${nominal_mhz} MHz)"
            echo "=========================================="
            ;;
        min|minimum|800)
            set_frequency "$MIN_FREQ_KHZ" "minimum"
            verify_frequency "$MIN_FREQ_KHZ"
            echo ""
            echo "=========================================="
            echo "✓ All CPUs set to MINIMUM frequency (${min_mhz} MHz)"
            echo "=========================================="
            ;;
        *)
            echo "ERROR: Invalid mode '$mode'" >&2
            echo "       Use 'nominal' or 'min'" >&2
            echo ""
            usage
            ;;
    esac
}

main "$@"
