#!/bin/bash
#
# CPU Configuration Script
# Sets CPU frequency and C-state profile for power measurement tests.
#
# Usage: sudo ./set_config.sh <freq> <cstate>
#
#   freq:   2200   — pin all CPUs at 2200 MHz (base/nominal)
#           800    — pin all CPUs at 800 MHz (minimum)
#
#   cstate: c6     — enable all C-states (POLL,C1,C1E,C6S,C6SP)
#           c1     — shallow sleep only (POLL,C1 enabled; C1E,C6S,C6SP disabled)
#
# Examples:
#   sudo ./set_config.sh 2200 c6   # Test 1 nominal — idle + deep sleep
#   sudo ./set_config.sh 800  c6   # Test 1 min     — idle + deep sleep
#   sudo ./set_config.sh 2200 c1   # Test 2 nominal — idle + shallow sleep
#   sudo ./set_config.sh 800  c1   # Test 2 min     — idle + shallow sleep
#
# For stress tests, run stress-ng on top of this configuration:
#   stress-ng --cpu 0 --timeout 60s
#
# Requires: root (sudo), intel_pstate in passive mode
#

set -euo pipefail

CPU_COUNT=288

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

usage() {
    sed -n '3,24p' "$0" | sed 's/^# \?//'
    exit 1
}

set_frequency() {
    local target_khz=$1
    local success=0

    echo "Setting frequency to $((target_khz / 1000)) MHz on all $CPU_COUNT CPUs..."

    # Ensure userspace governor is available (requires intel_pstate passive mode)
    local avail
    avail=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
    if ! echo "$avail" | grep -qw "userspace"; then
        echo "ERROR: userspace governor not available." >&2
        echo "  Ensure intel_pstate is in passive mode:" >&2
        echo "    echo passive | sudo tee /sys/devices/system/cpu/intel_pstate/status" >&2
        exit 1
    fi

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -d "$cpu_dir" ] || continue
        echo "userspace" > "$cpu_dir/scaling_governor" 2>/dev/null || true
        echo "$target_khz" > "$cpu_dir/scaling_min_freq"  2>/dev/null || true
        echo "$target_khz" > "$cpu_dir/scaling_max_freq"  2>/dev/null || true
        echo "$target_khz" > "$cpu_dir/scaling_setspeed"  2>/dev/null || true
        ((success++))
    done

    echo "  ✓ Configured $success CPUs"
}

set_cstates() {
    local mode=$1   # "c1" or "c6"
    local success=0

    if [ "$mode" = "c1" ]; then
        echo "C-states: shallow sleep only (C1E/C6S/C6SP disabled)..."
    else
        echo "C-states: all enabled (POLL/C1/C1E/C6S/C6SP)..."
    fi

    set_one_state() {
        local cpu=$1 state_name=$2 disable_val=$3
        local cpuidle="/sys/devices/system/cpu/cpu${cpu}/cpuidle"
        [ -d "$cpuidle" ] || return 0
        for state_dir in "$cpuidle"/state*; do
            [ -f "$state_dir/name" ] || continue
            name=$(cat "$state_dir/name")
            if [ "$name" = "$state_name" ] && [ -f "$state_dir/disable" ]; then
                echo "$disable_val" > "$state_dir/disable" 2>/dev/null || true
                return 0
            fi
        done
    }

    for cpu_num in $(seq 0 $((CPU_COUNT - 1))); do
        set_one_state "$cpu_num" "POLL" 0
        set_one_state "$cpu_num" "C1"   0
        if [ "$mode" = "c1" ]; then
            set_one_state "$cpu_num" "C1E"  1
            set_one_state "$cpu_num" "C6S"  1
            set_one_state "$cpu_num" "C6SP" 1
        else
            set_one_state "$cpu_num" "C1E"  0
            set_one_state "$cpu_num" "C6S"  0
            set_one_state "$cpu_num" "C6SP" 0
        fi
        ((success++))
    done

    echo "  ✓ Configured $success CPUs"
}

verify() {
    local target_khz=$1 mode=$2

    echo ""
    echo "--- Verification ---"

    # Frequency sample
    local ok=true
    for cpu_num in 0 71 143 215 287; do
        local f
        f=$(cat "/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_cur_freq" 2>/dev/null || echo "N/A")
        printf "  CPU %-3s: %s kHz\n" "$cpu_num" "$f"
        [ "$f" = "$target_khz" ] || ok=false
    done
    $ok && echo "  ✓ All sample CPUs at target frequency" || echo "  ! Some CPUs not at target (check sysfs)"

    # C-state sample (CPU 0)
    echo ""
    echo "  C-states (CPU 0):"
    for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        [ -d "$state_dir" ] || continue
        name=$(cat "$state_dir/name" 2>/dev/null || echo "?")
        dis=$(cat  "$state_dir/disable" 2>/dev/null || echo "?")
        [ "$dis" = "0" ] && status="ENABLED" || status="DISABLED"
        printf "    %-6s [%s]\n" "$name" "$status"
    done
}

main() {
    [ $# -eq 2 ] || usage

    local freq_arg=$1
    local cstate_arg=$2
    local target_khz

    case "$freq_arg" in
        2200) target_khz=2200000 ;;
        800)  target_khz=800000  ;;
        *) echo "ERROR: unknown frequency '$freq_arg' (use 2200 or 800)" >&2; usage ;;
    esac

    case "$cstate_arg" in
        c1|c6) ;;
        *) echo "ERROR: unknown cstate mode '$cstate_arg' (use c1 or c6)" >&2; usage ;;
    esac

    check_root

    echo "========================================"
    echo "CPU Configuration: ${freq_arg} MHz / ${cstate_arg^^}"
    echo "========================================"
    echo ""

    set_frequency "$target_khz"
    echo ""
    set_cstates "$cstate_arg"

    verify "$target_khz" "$cstate_arg"

    echo ""
    echo "========================================"
    echo "✓ Done. Start power_monitor.py to record."
    echo "========================================"
}

main "$@"
