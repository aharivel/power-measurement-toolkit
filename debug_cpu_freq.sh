#!/bin/bash

echo "=== CPU Frequency Debug Script ==="
echo ""

# 1. Check current CPU driver and available governors
echo "1. CPU Driver Information:"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
echo ""

echo "2. Available Governors:"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
echo ""

# 2. Check current governor for all CPUs
echo "3. Current Governor for Each CPU:"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu_num=$(basename "$cpu")
    if [ -f "$cpu/cpufreq/scaling_governor" ]; then
        governor=$(cat "$cpu/cpufreq/scaling_governor")
        echo "  $cpu_num: $governor"
    else
        echo "  $cpu_num: NO cpufreq directory"
    fi
done
echo ""

# 3. Check current frequency settings
echo "4. Current Frequency Settings:"
printf "  %-6s %-10s %-10s %-10s\n" "CPU" "Min" "Max" "Current"
printf "  %-6s %-10s %-10s %-10s\n" "---" "---" "---" "-------"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu_num=$(basename "$cpu")
    if [ -d "$cpu/cpufreq" ]; then
        min_freq=$(cat "$cpu/cpufreq/scaling_min_freq" 2>/dev/null || echo "N/A")
        max_freq=$(cat "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || echo "N/A")
        cur_freq=$(cat "$cpu/cpufreq/scaling_cur_freq" 2>/dev/null || echo "N/A")
        
        min_mhz=$((min_freq / 1000))
        max_mhz=$((max_freq / 1000))
        cur_mhz=$((cur_freq / 1000))
        
        printf "  %-6s %-10s %-10s %-10s\n" "$cpu_num" "${min_mhz} MHz" "${max_mhz} MHz" "${cur_mhz} MHz"
    fi
done
echo ""

# 4. Check if any CPUs are not locked correctly
echo "5. CPUs Not Locked to Minimum (if any):"
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu_num=$(basename "$cpu")
    if [ -d "$cpu/cpufreq" ]; then
        min_freq=$(cat "$cpu/cpufreq/scaling_min_freq" 2>/dev/null)
        max_freq=$(cat "$cpu/cpufreq/scaling_max_freq" 2>/dev/null)
        cur_freq=$(cat "$cpu/cpufreq/scaling_cur_freq" 2>/dev/null)
        
        if [ "$min_freq" != "$max_freq" ]; then
            echo "  $cpu_num: NOT LOCKED - min=$min_freq, max=$max_freq, cur=$cur_freq"
        elif [ $((cur_freq - min_freq)) -gt 100000 ]; then  # More than 100 MHz difference
            echo "  $cpu_num: LOCKED BUT WRONG - min=$min_freq, cur=$cur_freq"
        fi
    fi
done
echo ""

# 5. Check intel_pstate status
echo "6. Intel P-state Status:"
if [ -f /sys/devices/system/cpu/intel_pstate/status ]; then
    cat /sys/devices/system/cpu/intel_pstate/status
    echo ""
    echo "Intel P-state Settings:"
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo "  no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
    fi
fi
echo ""

echo "=== Debug Complete ==="
