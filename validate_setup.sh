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

# Check 1: Intel P-state mode
echo "1. Intel P-state Configuration"
if [ -f /sys/devices/system/cpu/intel_pstate/status ]; then
    status=$(cat /sys/devices/system/cpu/intel_pstate/status)
    if [ "$status" = "passive" ]; then
        print_check "ok" "Intel P-state in passive mode"
    else
        print_check "error" "Intel P-state in $status mode (MUST be passive!)"
        echo "     Fix: echo passive | sudo tee /sys/devices/system/cpu/intel_pstate/status"
    fi
else
    print_check "error" "Intel P-state interface not found"
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

    if [ "$min_freq" = "800000" ]; then
        print_check "ok" "Min frequency: 800 MHz"
    else
        print_check "warn" "Min frequency: $((min_freq / 1000)) MHz (expected 800 MHz)"
    fi

    if [ "$max_freq" -ge "2300000" ]; then
        print_check "ok" "Max frequency: $((max_freq / 1000)) MHz"
    else
        print_check "error" "Max frequency: $((max_freq / 1000)) MHz (expected >= 2300 MHz)"
        echo "     Check BIOS settings: Turbo Boost, C-States, CPU Power Management"
    fi
else
    print_check "error" "Cannot read frequency information"
fi
echo ""

# Check 4: C-states
echo "4. C-State Availability"
if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
    c6_found=false
    for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        if [ -f "$state_dir/name" ]; then
            name=$(cat "$state_dir/name")
            if [ "$name" = "C6" ]; then
                c6_found=true
                break
            fi
        fi
    done

    if [ "$c6_found" = true ]; then
        print_check "ok" "C6 state available"
    else
        print_check "warn" "C6 state not found (check BIOS C-States setting)"
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
