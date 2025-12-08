#!/bin/bash
#
# Fixed frequency setting script
# Sets min/max limits first, then setspeed
#

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 [nominal|min]"
    exit 1
fi

case "$1" in
    nominal)
        TARGET_FREQ=2300000
        echo "Setting all CPUs to NOMINAL frequency: 2300 MHz"
        ;;
    min)
        TARGET_FREQ=800000
        echo "Setting all CPUs to MINIMUM frequency: 800 MHz"
        ;;
    *)
        echo "ERROR: Invalid argument. Use 'nominal' or 'min'"
        exit 1
        ;;
esac

# Disable turbo
echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

# Set frequency for ALL CPUs
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$cpu_dir/cpufreq" ] || continue

    # Set userspace governor
    echo userspace > "$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true

    # Set min/max to target (this removes any restrictions)
    echo ${TARGET_FREQ} > "$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
    echo ${TARGET_FREQ} > "$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true

    # Set setspeed to target
    echo ${TARGET_FREQ} > "$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
done

sleep 2

echo ""
echo "Verification:"
echo "All CPU frequencies:"
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq | awk '{print $1/1000 " MHz"}' | sort | uniq -c
