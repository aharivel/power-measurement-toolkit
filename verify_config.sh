#!/bin/bash
#
# Configuration Verification Script
# Verifies CPU frequency, C-states, and turbo settings
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
    --detailed, -d      Show per-CPU frequency details

Examples:
    $SCRIPT_NAME              # Quick summary
    $SCRIPT_NAME --detailed   # Full per-CPU frequencies
EOF
    exit 1
}

print_section() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

check_turbo_status() {
    print_section "Turbo Boost"

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" = "1" ]; then
            echo "  ✓ Turbo Boost: DISABLED (good for consistent measurements)"
        else
            echo "  ! Turbo Boost: ENABLED (may cause frequency variation)"
        fi
    else
        echo "  ? intel_pstate interface not found"
    fi
}

check_frequency_config() {
    print_section "CPU Frequency"

    local cpu0_cpufreq="/sys/devices/system/cpu/cpu0/cpufreq"

    if [ ! -d "$cpu0_cpufreq" ]; then
        echo "  ERROR: cpufreq interface not found"
        return 1
    fi

    local governor min_freq max_freq cur_freq
    governor=$(cat "$cpu0_cpufreq/scaling_governor")
    min_freq=$(cat "$cpu0_cpufreq/scaling_min_freq")
    max_freq=$(cat "$cpu0_cpufreq/scaling_max_freq")
    cur_freq=$(cat "$cpu0_cpufreq/scaling_cur_freq")

    echo "  Governor:  $governor"
    echo "  Range:     $min_freq - $max_freq kHz"
    echo "  Current (CPU 0): $cur_freq kHz"

    if [ "$min_freq" = "$max_freq" ]; then
        echo "  ✓ Frequency PINNED to: $((min_freq / 1000)) MHz"
    else
        echo "  ! Frequency NOT pinned (min != max)"
    fi

    echo ""
    if [ "$DETAILED" = true ]; then
        echo "  Per-CPU frequencies:"
        for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
            [ -d "$cpu_dir" ] || continue
            cpu_num=$(basename "$(dirname "$cpu_dir")" | sed 's/cpu//')
            freq=$(cat "$cpu_dir/scaling_cur_freq")
            printf "    CPU %-3s: %8s kHz\n" "$cpu_num" "$freq"
        done
    else
        echo "  Sample frequencies (CPUs 0,71,143,215,287):"
        for cpu_num in 0 71 143 215 287; do
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

    echo "  C-states (CPU 0):"
    echo ""

    local enabled_states=()
    local disabled_states=()

    for state_dir in "$cpuidle_dir"/state*; do
        [ -d "$state_dir" ] || continue
        name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
        latency=$(cat "$state_dir/latency" 2>/dev/null || echo "N/A")
        disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")

        if [ "$disabled" = "0" ]; then
            status="✓ ENABLED "
            enabled_states+=("$name")
        else
            status="✗ DISABLED"
            disabled_states+=("$name")
        fi

        printf "    %-6s [%s]  latency: %4s us\n" "$name" "$status" "$latency"
    done

    echo ""
    echo "  Enabled:  ${enabled_states[*]}"
    [ ${#disabled_states[@]} -gt 0 ] && echo "  Disabled: ${disabled_states[*]}"

    echo ""
    if [[ " ${enabled_states[*]} " =~ " C6S " ]] || [[ " ${enabled_states[*]} " =~ " C6SP " ]]; then
        echo "  → Suitable for Test 1 (deep sleep)"
    elif [[ " ${enabled_states[*]} " =~ " C1 " ]]; then
        echo "  → Suitable for Test 2 (shallow sleep)"
    fi
}

check_power_interfaces() {
    print_section "Power Measurement Interfaces"

    # RAPL
    local rapl_base="/sys/devices/virtual/powercap/intel-rapl"
    local found=false
    for pkg_dir in "$rapl_base"/intel-rapl:*/; do
        [ -f "${pkg_dir}energy_uj" ] || continue
        pkg=$(basename "$pkg_dir")
        energy=$(cat "${pkg_dir}energy_uj")
        echo "  ✓ RAPL $pkg: $energy uJ"
        found=true
    done
    $found || echo "  ✗ RAPL: not available"

    # IPMI
    if command -v ipmitool &>/dev/null; then
        echo "  ✓ ipmitool: installed"
        if sudo ipmitool dcmi power reading &>/dev/null; then
            power=$(sudo ipmitool dcmi power reading | awk '/Instantaneous/{print $4}')
            echo "    Current: $power W"
        else
            echo "    ! IPMI command failed (check BMC)"
        fi
    else
        echo "  ✗ ipmitool: NOT installed"
    fi
}

generate_summary() {
    print_section "Summary"

    local issues=()
    local warnings=()

    local min_freq max_freq
    min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "0")
    max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0")

    if [ "$min_freq" = "$max_freq" ] && [ "$min_freq" != "0" ]; then
        echo "  ✓ CPU frequency pinned to $((min_freq / 1000)) MHz"
    else
        warnings+=("CPU frequency not pinned")
    fi

    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        [ "$no_turbo" = "1" ] && echo "  ✓ Turbo disabled" || warnings+=("Turbo boost enabled")
    fi

    if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
        c6s_disabled=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state3/disable 2>/dev/null || echo "")
        if [ "$c6s_disabled" = "0" ]; then
            echo "  ✓ C6S enabled (deep sleep — Test 1)"
        elif [ "$c6s_disabled" = "1" ]; then
            echo "  ✓ C6S disabled (shallow sleep — Test 2)"
        fi
    fi

    if [ -f /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj ]; then
        echo "  ✓ RAPL available"
    else
        issues+=("RAPL not available")
    fi

    command -v ipmitool &>/dev/null && echo "  ✓ ipmitool installed" || issues+=("ipmitool not installed")

    if [ ${#warnings[@]} -gt 0 ]; then
        echo ""
        echo "  Warnings:"
        for w in "${warnings[@]}"; do echo "    ⚠ $w"; done
    fi

    if [ ${#issues[@]} -gt 0 ]; then
        echo ""
        echo "  Issues:"
        for i in "${issues[@]}"; do echo "    ✗ $i"; done
        return 1
    fi

    echo ""
    echo "  ✓ Ready for power measurement"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --detailed|-d) DETAILED=true; shift ;;
            --help|-h) usage ;;
            *) echo "ERROR: Unknown option '$1'" >&2; usage ;;
        esac
    done

    echo "========================================"
    echo "CPU Configuration Verification"
    echo "========================================"

    check_turbo_status
    check_frequency_config
    check_cstate_config
    check_power_interfaces
    generate_summary

    echo ""
    echo "========================================"
}

main "$@"
