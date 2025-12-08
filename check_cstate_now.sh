#!/bin/bash
#
# Quick C-State Check
# Shows current C-state residency and which states CPUs are using
#

echo "=========================================="
echo "Current C-State Status"
echo "=========================================="
echo ""

# Check which C-states are enabled/disabled
echo "C-State Configuration (CPU 0):"
for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    if [ -d "$state_dir" ]; then
        state=$(basename "$state_dir")
        name=$(cat "$state_dir/name")
        disabled=$(cat "$state_dir/disable")

        if [ "$disabled" = "0" ]; then
            status="✓ ENABLED "
        else
            status="✗ DISABLED"
        fi

        printf "  %-8s %-6s [%s]\n" "$state" "$name" "$status"
    fi
done
echo ""

# Show cumulative time in each state for CPU 0
echo "C-State Residency (CPU 0 since boot):"
total_time=0
for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    if [ -d "$state_dir" ]; then
        time=$(cat "$state_dir/time" 2>/dev/null || echo "0")
        total_time=$((total_time + time))
    fi
done

for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    if [ -d "$state_dir" ]; then
        state=$(basename "$state_dir")
        name=$(cat "$state_dir/name")
        time=$(cat "$state_dir/time" 2>/dev/null || echo "0")
        usage=$(cat "$state_dir/usage" 2>/dev/null || echo "0")

        # Convert time from microseconds to seconds
        time_sec=$((time / 1000000))

        # Calculate percentage
        if [ $total_time -gt 0 ]; then
            percent=$((time * 100 / total_time))
        else
            percent=0
        fi

        printf "  %-8s %-6s: %3d%% | %10ss | %10s entries\n" \
            "$state" "$name" "$percent" "$time_sec" "$usage"
    fi
done
echo ""

# Quick check: are any CPUs in deep sleep?
echo "Quick Analysis:"
c6_time=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state3/time 2>/dev/null || echo "0")
c1_time=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state1/time 2>/dev/null || echo "0")

c6_sec=$((c6_time / 1000000))
c1_sec=$((c1_time / 1000000))

echo "  C1 time:  ${c1_sec}s"
echo "  C6 time:  ${c6_sec}s"

if [ $c6_time -gt $c1_time ]; then
    echo "  → CPU 0 is spending more time in C6 (deep sleep) ✓"
elif [ $c1_time -gt 0 ]; then
    echo "  → CPU 0 is spending more time in C1 (shallow sleep)"
else
    echo "  → CPU 0 is mostly active (not sleeping)"
fi
echo ""

# Check CPU load
echo "CPU Load:"
uptime
echo ""

echo "Note: Run './monitor_cstates.sh' for real-time monitoring"
