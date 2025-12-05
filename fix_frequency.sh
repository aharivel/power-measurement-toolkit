#!/bin/bash
#
# Quick fix to set CPU frequency to 2300 MHz (nominal)
#
# This script works with intel_pstate in passive mode
#

set -euo pipefail

TARGET_FREQ=2300000  # 2300 MHz in kHz

echo "Setting all CPUs to ${TARGET_FREQ} kHz (2300 MHz)..."
echo ""

# Disable turbo
echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "Could not disable turbo"

# For each CPU
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$cpu_dir/cpufreq" ] || continue

    cpu_num=$(basename "$cpu_dir" | sed 's/cpu//')

    # Set governor to userspace
    echo userspace > "$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true

    # Set both min and max to target frequency (this pins it)
    echo ${TARGET_FREQ} > "$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
    echo ${TARGET_FREQ} > "$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true

    # Try setspeed as well (may or may not work)
    echo ${TARGET_FREQ} > "$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
done

echo "Done. Waiting 2 seconds for frequencies to stabilize..."
sleep 2

echo ""
echo "Verification - Current frequencies:"
for cpu_num in 0 1 10 20 30; do
    freq_file="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_cur_freq"
    if [ -f "$freq_file" ]; then
        freq=$(cat "$freq_file")
        freq_mhz=$((freq / 1000))
        printf "  CPU %-3s: %4s MHz\n" "$cpu_num" "$freq_mhz"
    fi
done

echo ""
echo "Expected: 2300 MHz on all CPUs"
