#!/bin/bash
#
# Setup Validation Script
# Checks if the system is properly configured for power measurement tests
#

set -euo pipefail

ERRORS=0
WARNINGS=0

print_check() {
    local status=$1
    local message=$2

    if [ "$status" = "ok" ]; then
        echo "  ✓ $message"
    elif [ "$status" = "warn" ]; then
        echo "  ⚠ $message"
        ((WARNINGS++))
    else
        echo "  ✗ $message"
        ((ERRORS++))
    fi
}

echo "========================================="
echo "Power Measurement Setup Validation"
echo "========================================="
echo ""

# Check 1: CPU Frequency Driver
echo "1. CPU Frequency Driver"
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]; then
    driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
    print_check "ok" "Driver: $driver"

    # Check Intel P-state specific settings
    if [ -f /sys/devices/system/cpu/intel_pstate/status ]; then
        status=$(cat /sys/devices/system/cpu/intel_pstate/status)
        if [ "$status" = "passive" ]; then
            print_check "ok" "Intel P-state in passive mode"
        else
            print_check "warn" "Intel P-state in $status mode (passive recommended for fixed freq)"
        fi
    fi

    # Check AMD P-state specific settings
    if [ -d /sys/devices/system/cpu/amd_pstate ]; then
        status=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo "unknown")
        print_check "ok" "AMD P-state status: $status"
    fi
else
    print_check "error" "cpufreq interface not found"
fi
echo ""

# Check 2: Available governors
echo "2. CPU Frequency Governors"
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
    governors=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
    if echo "$governors" | grep -q "userspace"; then
        print_check "ok" "Userspace governor available"
    else
        print_check "error" "Userspace governor NOT available"
        echo "     Available: $governors"
    fi
else
    print_check "error" "cpufreq interface not found"
fi
echo ""

# Check 3: Frequency range
echo "3. CPU Frequency Range"
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq ]; then
    min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq)
    max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
    min_mhz=$((min_freq / 1000))
    max_mhz=$((max_freq / 1000))

    # Min frequency varies by platform (Intel ~800MHz, AMD EPYC ~400MHz)
    if [ "$min_freq" -le "1000000" ]; then
        print_check "ok" "Min frequency: ${min_mhz} MHz"
    else
        print_check "warn" "Min frequency: ${min_mhz} MHz (expected < 1000 MHz)"
    fi

    # Max frequency should be reasonable for server CPUs
    if [ "$max_freq" -ge "2000000" ]; then
        print_check "ok" "Max frequency: ${max_mhz} MHz"
    else
        print_check "warn" "Max frequency: ${max_mhz} MHz (expected >= 2000 MHz)"
    fi

    print_check "ok" "Frequency range: ${min_mhz} - ${max_mhz} MHz"
else
    print_check "error" "Cannot read frequency information"
fi
echo ""

# Check 4: C-states
echo "4. C-State Availability"
if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
    # Count available states and find deepest
    state_count=0
    deepest_state=""
    deepest_latency=0
    for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        if [ -f "$state_dir/name" ]; then
            name=$(cat "$state_dir/name")
            latency=$(cat "$state_dir/latency" 2>/dev/null || echo "0")
            ((state_count++))
            if [ "$latency" -gt "$deepest_latency" ]; then
                deepest_latency=$latency
                deepest_state=$name
            fi
        fi
    done

    if [ "$state_count" -ge 3 ]; then
        print_check "ok" "Deep C-state available: $deepest_state (${deepest_latency}us latency)"
    elif [ "$state_count" -ge 2 ]; then
        print_check "warn" "Only $state_count C-states found (deepest: $deepest_state). Check BIOS for deeper states."
    else
        print_check "warn" "Only $state_count C-state found. Check BIOS C-States setting."
    fi
else
    print_check "error" "cpuidle interface not found"
fi
echo ""

# Check 5: RAPL
echo "5. RAPL Interface"
if lsmod | grep -q msr; then
    print_check "ok" "MSR module loaded"
else
    print_check "error" "MSR module not loaded"
    echo "     Fix: sudo modprobe msr"
fi

if [ -f /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj ]; then
    print_check "ok" "RAPL interface accessible"
else
    print_check "error" "RAPL interface not found"
fi
echo ""

# Check 6: IPMI
echo "6. IPMI Tool"
if command -v ipmitool &>/dev/null; then
    print_check "ok" "ipmitool installed"

    if sudo ipmitool dcmi power reading &>/dev/null; then
        print_check "ok" "IPMI power reading works"
    else
        print_check "warn" "IPMI command failed (check BMC configuration)"
    fi
else
    print_check "error" "ipmitool not installed"
    echo "     Fix: sudo dnf install ipmitool"
fi
echo ""

# Check 7: Other tools
echo "7. Required Tools"
tools=("stress-ng" "tuned" "python3")
for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        print_check "ok" "$tool installed"
    else
        print_check "error" "$tool not installed"
    fi
done
echo ""

# Check 8: Tuned service
echo "8. Tuned Service"
if systemctl is-active --quiet tuned; then
    print_check "ok" "Tuned service running"
else
    print_check "warn" "Tuned service not running"
    echo "     Fix: sudo systemctl enable --now tuned"
fi
echo ""

# Summary
echo "========================================="
echo "Summary"
echo "========================================="

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✓ All checks passed! System is ready for testing."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠  $WARNINGS warning(s) found. System should work but review warnings."
    exit 0
else
    echo "✗ $ERRORS error(s) and $WARNINGS warning(s) found."
    echo ""
    echo "Critical issues must be fixed before running tests."
    echo "Review the errors above and apply the suggested fixes."
    exit 1
fi
