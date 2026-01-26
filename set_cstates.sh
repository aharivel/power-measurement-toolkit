#!/bin/bash
#
# C-State Configuration Script
# Configure CPU idle states for power measurement tests
#
# Usage: sudo ./set_cstates.sh [c1|deep|all]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [c1|deep|all]

Configure CPU C-states (idle states) for testing.

Arguments:
    c1      Allow only C1 state (shallow sleep, fast wake-up)
            - Enables: state0 (POLL), state1 (C1)
            - Disables: state2+ (deeper states)
            - Use for Test 2

    deep    Allow deepest available C-state
            - Enables all available states
            - Use for Test 1
            (alias: c6, for backwards compatibility)

    all     Enable all C-states (default behavior)
            - Enables all available states

Requirements:
    - Must run as root (sudo)
    - cpuidle interface available at /sys/devices/system/cpu/cpu*/cpuidle

Examples:
    sudo $SCRIPT_NAME deep   # Enable deep sleep for Test 1
    sudo $SCRIPT_NAME c1     # Limit to shallow sleep for Test 2
    sudo $SCRIPT_NAME all    # Enable all states (default)

Notes:
    C-state levels vary by platform:

    Intel (typical):
    - POLL (state0): CPU polls, no power saving
    - C1 (state1): CPU halted (~1us latency)
    - C1E (state2): Enhanced C1 (~4us latency)
    - C6 (state3): Deep sleep (~170us latency)

    AMD EPYC (typical):
    - POLL (state0): CPU polls, no power saving
    - C1 (state1): CPU halted (~1us latency)
    - C2 (state2): ACPI idle (~800us latency)

    This script uses state numbers for cross-platform compatibility.
EOF
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

# Set state by number (0, 1, 2, ...) - works across Intel and AMD
set_state_by_number() {
    local cpu_dir=$1
    local state_num=$2
    local enable=$3  # 0 = enable, 1 = disable

    local state_file="$cpu_dir/cpuidle/state${state_num}/disable"
    if [ -f "$state_file" ]; then
        echo "$enable" > "$state_file" 2>/dev/null || true
    fi
}

# Get available states for a CPU
get_max_state() {
    local cpu_dir=$1
    local max_state=-1
    for state_dir in "$cpu_dir"/cpuidle/state*; do
        if [ -d "$state_dir" ]; then
            state_num=$(basename "$state_dir" | sed 's/state//')
            if [ "$state_num" -gt "$max_state" ]; then
                max_state=$state_num
            fi
        fi
    done
    echo "$max_state"
}

configure_c1_mode() {
    echo "Configuring C1 mode (shallow sleep only)..."
    echo "  Enabling: state0 (POLL), state1 (C1)"
    echo "  Disabling: state2+ (deeper states)"
    echo ""

    local success_count=0

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_dir/cpuidle" ] || continue

        # Enable state0 (POLL) and state1 (C1)
        set_state_by_number "$cpu_dir" 0 0
        set_state_by_number "$cpu_dir" 1 0

        # Disable state2 and beyond (deeper states)
        local max_state=$(get_max_state "$cpu_dir")
        for state_num in $(seq 2 "$max_state"); do
            set_state_by_number "$cpu_dir" "$state_num" 1
        done

        ((success_count++))
    done

    echo "Configured $success_count CPUs for C1 mode"
}

configure_deep_mode() {
    echo "Configuring deep sleep mode (all states enabled)..."
    echo "  Enabling: all available states"
    echo ""

    local success_count=0

    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$cpu_dir/cpuidle" ] || continue

        # Enable all states
        local max_state=$(get_max_state "$cpu_dir")
        for state_num in $(seq 0 "$max_state"); do
            set_state_by_number "$cpu_dir" "$state_num" 0
        done

        ((success_count++))
    done

    echo "Configured $success_count CPUs for deep sleep mode"
}

configure_all_mode() {
    echo "Enabling all C-states (default mode)..."
    configure_deep_mode
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
        deep|c6)
            configure_deep_mode
            verify_cstates
            echo ""
            echo "✓ C-states configured for Test 1 (deep sleep enabled)"
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
