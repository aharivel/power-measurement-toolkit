#!/bin/bash
#
# C-State Configuration Script
# Configure CPU idle states for power measurement tests
#
# Usage: sudo ./set_cstates.sh [c1|c6|all]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [c1|c6|all]

Configure CPU C-states (idle states) for testing.

Arguments:
    c1      Allow only C1 state (shallow sleep, fast wake-up)
            - Disables: C1E, C6S, C6SP
            - Use for Test 2

    c6      Allow C6S/C6SP states (deep sleep, slower wake-up)
            - Enables: C1, C1E, C6S, C6SP (all states)
            - Use for Test 1

    all     Enable all C-states (default behavior)
            - Enables: POLL, C1, C1E, C6S, C6SP

Requirements:
    - Must run as root (sudo)
    - cpuidle interface available at /sys/devices/system/cpu/cpu*/cpuidle

Examples:
    sudo $SCRIPT_NAME c6     # Enable deep sleep for Test 1
    sudo $SCRIPT_NAME c1     # Limit to shallow sleep for Test 2
    sudo $SCRIPT_NAME all    # Enable all states (default)

Notes:
    C-state levels on Intel Xeon 6780E (from shallowest to deepest):
    - POLL  (state0): CPU polls, no power saving (0us latency)
    - C1    (state1): CPU halted, immediate wake-up (1us latency)
    - C1E   (state2): Enhanced C1 with lower voltage (2us latency)
    - C6S   (state3): Module-scoped deep sleep — all 4 cores in a module
                      must request C6S before the module+L2 powers down (270us latency)
    - C6SP  (state4): Package-scoped deep sleep — all modules must enter C6S
                      before the entire socket enters the deepest power state (310us latency)

    Deeper states save more power but have higher wake-up latency.
EOF
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

set_cstate_for_cpu() {
    local cpu_num=$1
    local state_name=$2
    local enable=$3  # 0 = enable, 1 = disable

    local cpuidle_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpuidle"

    if [ ! -d "$cpuidle_dir" ]; then
        return 1
    fi

    # Find the state directory matching the name
    for state_dir in "$cpuidle_dir"/state*; do
        if [ -f "$state_dir/name" ]; then
            name=$(cat "$state_dir/name")
            if [ "$name" = "$state_name" ]; then
                if [ -f "$state_dir/disable" ]; then
                    echo "$enable" > "$state_dir/disable" 2>/dev/null || {
                        return 1
                    }
                    return 0
                fi
            fi
        fi
    done

    return 1
}

configure_c1_mode() {
    echo "Configuring C1 mode (shallow sleep only)..."
    echo "  Enabling: POLL, C1"
    echo "  Disabling: C1E, C6S, C6SP"
    echo ""

    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    local success_count=0

    for cpu_num in $(seq 0 $((cpu_count - 1))); do
        set_cstate_for_cpu "$cpu_num" "POLL" 0 || true
        set_cstate_for_cpu "$cpu_num" "C1" 0 || true
        set_cstate_for_cpu "$cpu_num" "C1E" 1 || true
        set_cstate_for_cpu "$cpu_num" "C6S" 1 || true
        set_cstate_for_cpu "$cpu_num" "C6SP" 1 || true

        ((success_count++))
    done

    echo "Configured $success_count CPUs for C1 mode"
}

configure_c6_mode() {
    echo "Configuring C6S/C6SP mode (deep sleep allowed)..."
    echo "  Enabling: POLL, C1, C1E, C6S, C6SP"
    echo ""

    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    local success_count=0

    for cpu_num in $(seq 0 $((cpu_count - 1))); do
        set_cstate_for_cpu "$cpu_num" "POLL" 0 || true
        set_cstate_for_cpu "$cpu_num" "C1" 0 || true
        set_cstate_for_cpu "$cpu_num" "C1E" 0 || true
        set_cstate_for_cpu "$cpu_num" "C6S" 0 || true
        set_cstate_for_cpu "$cpu_num" "C6SP" 0 || true

        ((success_count++))
    done

    echo "Configured $success_count CPUs for C6S/C6SP mode"
}

configure_all_mode() {
    echo "Enabling all C-states (default mode)..."
    echo "  Enabling: POLL, C1, C1E, C6S, C6SP"
    echo ""

    local cpu_count=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
    local success_count=0

    for cpu_num in $(seq 0 $((cpu_count - 1))); do
        set_cstate_for_cpu "$cpu_num" "POLL" 0 || true
        set_cstate_for_cpu "$cpu_num" "C1" 0 || true
        set_cstate_for_cpu "$cpu_num" "C1E" 0 || true
        set_cstate_for_cpu "$cpu_num" "C6S" 0 || true
        set_cstate_for_cpu "$cpu_num" "C6SP" 0 || true

        ((success_count++))
    done

    echo "Configured $success_count CPUs with all C-states enabled"
}

verify_cstates() {
    echo ""
    echo "Verifying C-state configuration..."
    echo ""

    # Check CPU 0 as representative
    local cpuidle_dir="/sys/devices/system/cpu/cpu0/cpuidle"

    if [ ! -d "$cpuidle_dir" ]; then
        echo "ERROR: cpuidle interface not found" >&2
        return 1
    fi

    echo "C-states for CPU 0:"
    for state_dir in "$cpuidle_dir"/state*; do
        if [ -d "$state_dir" ]; then
            state=$(basename "$state_dir")
            name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
            desc=$(cat "$state_dir/desc" 2>/dev/null || echo "N/A")
            disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")

            if [ "$disabled" = "0" ]; then
                status="ENABLED"
            else
                status="DISABLED"
            fi

            printf "  %-8s %-6s %-20s [%s]\n" "$state" "$name" "$desc" "$status"
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
        c1)
            configure_c1_mode
            verify_cstates
            echo ""
            echo "✓ C-states configured for Test 2 (C1 only - shallow sleep)"
            ;;
        c6)
            configure_c6_mode
            verify_cstates
            echo ""
            echo "✓ C-states configured for Test 1 (C6S/C6SP enabled - deep sleep)"
            ;;
        all)
            configure_all_mode
            verify_cstates
            echo ""
            echo "✓ All C-states enabled (default configuration)"
            ;;
        *)
            echo "ERROR: Invalid mode '$mode'" >&2
            echo ""
            usage
            ;;
    esac
}

main "$@"
