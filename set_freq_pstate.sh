#!/bin/bash
#
# Set CPU frequency using intel_pstate active mode
# Works with percentage-based controls instead of exact frequencies
#

set -euo pipefail

usage() {
    echo "Usage: sudo $0 [min|max]"
    echo ""
    echo "  min  - Set to minimum frequency (800 MHz)"
    echo "  max  - Set to maximum available frequency (1600 MHz)"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

if [ $# -ne 1 ]; then
    usage
fi

MODE=$1

# Disable turbo
echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

case $MODE in
    min|minimum)
        echo "Setting CPUs to MINIMUM frequency (800 MHz)..."
        # Set min and max to lowest percentage
        echo 0 > /sys/devices/system/cpu/intel_pstate/min_perf_pct
        echo 0 > /sys/devices/system/cpu/intel_pstate/max_perf_pct

        # Use powersave governor
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo powersave > "$cpu"
        done
        ;;

    max|maximum)
        echo "Setting CPUs to MAXIMUM frequency (1600 MHz)..."
        # Set to 100% of available
        echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct
        echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct

        # Use performance governor
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$cpu" ] && echo performance > "$cpu"
        done
        ;;

    *)
        usage
        ;;
esac

sleep 2

echo ""
echo "Current settings:"
echo "  Min perf pct: $(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct)"
echo "  Max perf pct: $(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)"
echo "  No turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
echo ""
echo "Current frequencies:"
for cpu_num in 0 10 20 30; do
    freq=$(cat /sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")
    if [ "$freq" != "N/A" ]; then
        freq_mhz=$((freq / 1000))
        printf "  CPU %-3s: %4s MHz\n" "$cpu_num" "$freq_mhz"
    fi
done
