#!/bin/bash
#
# Tuned Profile Management for Power Tests
#
# Simplifies switching between test profiles and verifying configuration
#
# Usage: sudo ./manage_test_profile.sh [command]
#

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [command]

Manage tuned profiles for power measurement tests.

Commands:
    list                    List all available power test profiles
    active                  Show currently active profile
    set PROFILE             Activate a specific profile
    verify                  Verify current configuration
    restore                 Restore to default system profile

Profile Names:
    powertest-1-c6-nominal      Test 1: Idle C6 @ 2300MHz
    powertest-1-c6-min          Test 1: Idle C6 @ 800MHz
    powertest-2-c1-nominal      Test 2: Idle C1 @ 2300MHz
    powertest-2-c1-min          Test 2: Idle C1 @ 800MHz
    powertest-3-stress-nominal  Test 3: Stress @ 2300MHz
    powertest-3-stress-min      Test 3: Stress @ 800MHz
    powertest-4-dpdk-nominal    Test 4: DPDK @ 2300MHz (requires reboot)
    powertest-4-dpdk-min        Test 4: DPDK @ 800MHz (requires reboot)

Examples:
    sudo $SCRIPT_NAME list
    sudo $SCRIPT_NAME active
    sudo $SCRIPT_NAME set powertest-1-c6-nominal
    sudo $SCRIPT_NAME verify
    sudo $SCRIPT_NAME restore

Notes:
    - All profile changes take effect immediately (except Test 4 isolation)
    - Test 4 profiles require reboot for CPU isolation kernel parameters
    - Always verify configuration after switching profiles
EOF
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

list_profiles() {
    echo "Available Power Test Profiles:"
    echo ""

    tuned-adm list | grep -E "powertest-" | while read -r line; do
        profile=$(echo "$line" | awk '{print $2}')
        echo "  $profile"
    done

    echo ""
    echo "Use '$SCRIPT_NAME set PROFILE' to activate a profile"
}

show_active() {
    echo "Currently Active Profile:"
    echo ""
    tuned-adm active
    echo ""

    # Show brief configuration
    if tuned-adm active | grep -q "powertest-"; then
        echo "Configuration:"

        # Show frequency
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
            freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
            freq_mhz=$((freq / 1000))
            echo "  CPU Frequency (CPU0): ${freq_mhz} MHz"
        fi

        # Show turbo status
        if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
            no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
            if [ "$no_turbo" = "1" ]; then
                echo "  Turbo: disabled"
            else
                echo "  Turbo: enabled"
            fi
        fi

        # Show C-states
        if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
            echo "  C-states (CPU0):"
            for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
                if [ -d "$state_dir" ]; then
                    name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
                    disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")
                    if [ "$disabled" = "0" ]; then
                        status="enabled"
                    else
                        status="disabled"
                    fi
                    echo "    $name: $status"
                fi
            done
        fi
    fi
}

set_profile() {
    local profile=$1

    # Validate profile name
    if ! tuned-adm list | grep -q "$profile"; then
        echo "ERROR: Profile '$profile' not found" >&2
        echo "" >&2
        echo "Available profiles:" >&2
        list_profiles >&2
        exit 1
    fi

    echo "Activating profile: $profile"
    echo ""

    tuned-adm profile "$profile"

    # Wait a moment for profile to apply
    sleep 2

    echo ""
    echo "✓ Profile activated successfully"
    echo ""

    # Show current configuration
    show_active

    # Warn about reboot if DPDK profile
    if [[ "$profile" == *"dpdk"* ]]; then
        echo ""
        echo "⚠  WARNING: DPDK profiles require REBOOT for CPU isolation to take effect"
        echo "   The frequency and C-state settings are active now, but isolation"
        echo "   requires kernel parameters that only apply after reboot."
    fi
}

verify_config() {
    echo "Verifying Current Configuration"
    echo "========================================"
    echo ""

    # Active profile
    echo "Active Profile:"
    tuned-adm active
    echo ""

    # CPU Frequency
    echo "CPU Frequency Configuration:"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        echo "  Governor: $governor"
    fi

    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
        freq_mhz=$((freq / 1000))
        echo "  Current frequency (CPU0): ${freq_mhz} MHz"
    fi

    # Sample a few more CPUs
    echo "  Sample frequencies:"
    for cpu_num in 0 10 20 30; do
        freq_file="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_cur_freq"
        if [ -f "$freq_file" ]; then
            freq=$(cat "$freq_file")
            freq_mhz=$((freq / 1000))
            printf "    CPU %-3s: %4s MHz\n" "$cpu_num" "$freq_mhz"
        fi
    done
    echo ""

    # Turbo status
    echo "Turbo Boost:"
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [ "$no_turbo" = "1" ]; then
            echo "  Status: disabled ✓"
        else
            echo "  Status: enabled ⚠"
        fi
    fi
    echo ""

    # C-states
    echo "C-State Configuration (CPU0):"
    if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
        for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
            if [ -d "$state_dir" ]; then
                state=$(basename "$state_dir")
                name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
                disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")
                if [ "$disabled" = "0" ]; then
                    status="✓ enabled"
                else
                    status="✗ disabled"
                fi
                printf "  %-8s %-6s [%s]\n" "$state" "$name" "$status"
            fi
        done
    fi
    echo ""

    # Check isolation (if applicable)
    if grep -q "isolcpus=" /proc/cmdline 2>/dev/null; then
        echo "CPU Isolation:"
        isolcpus=$(grep -o "isolcpus=[^ ]*" /proc/cmdline)
        echo "  Kernel parameter: $isolcpus"
    fi

    echo ""
    echo "========================================"
}

restore_default() {
    echo "Restoring default system profile..."
    echo ""

    # Use balanced or throughput-performance as default
    default_profile="balanced"
    if tuned-adm list | grep -q "throughput-performance"; then
        default_profile="throughput-performance"
    fi

    tuned-adm profile "$default_profile"

    sleep 2

    echo ""
    echo "✓ Restored to default profile: $default_profile"
    echo ""

    show_active
}

main() {
    if [ $# -lt 1 ]; then
        usage
    fi

    command=$1

    case "$command" in
        list)
            list_profiles
            ;;
        active|status)
            show_active
            ;;
        set|activate)
            check_root
            if [ $# -ne 2 ]; then
                echo "ERROR: 'set' command requires profile name" >&2
                echo "Usage: $SCRIPT_NAME set PROFILE" >&2
                exit 1
            fi
            set_profile "$2"
            ;;
        verify|check)
            verify_config
            ;;
        restore|default)
            check_root
            restore_default
            ;;
        --help|-h|help)
            usage
            ;;
        *)
            echo "ERROR: Unknown command '$command'" >&2
            echo ""
            usage
            ;;
    esac
}

main "$@"
