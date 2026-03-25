#!/bin/bash

echo "=== Force CPU Frequency Fix ==="
echo ""

# Check if we're root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (use sudo)"
    exit 1
fi

# Set all CPUs to userspace governor first
echo "Setting all CPUs to userspace governor..."
for cpu_num in $(seq 0 287); do
    cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}"
    if [ -d "$cpu_dir" ] && [ -f "$cpu_dir/cpufreq/scaling_governor" ]; then
        echo "userspace" > "$cpu_dir/cpufreq/scaling_governor"
        echo "  CPU${cpu_num}: governor set to userspace"
    fi
done
echo ""

# Set frequency limits for all CPUs
echo "Setting frequency limits to 800 MHz for all CPUs..."
for cpu_num in $(seq 0 287); do
    cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}"
    cpufreq_dir="$cpu_dir/cpufreq"
    
    if [ -d "$cpufreq_dir" ]; then
        # Set min and max to 800000 kHz (800 MHz)
        echo "800000" > "$cpufreq_dir/scaling_min_freq"
        echo "800000" > "$cpufreq_dir/scaling_max_freq"
        
        # Set the actual frequency via setspeed
        if [ -f "$cpufreq_dir/scaling_setspeed" ]; then
            echo "800000" > "$cpufreq_dir/scaling_setspeed"
        fi
        
        echo "  CPU${cpu_num}: min=800MHz, max=800MHz"
    fi
done
echo ""

# Verify the settings
echo "Verifying settings..."
echo "Sample CPUs (0, 31, 63):"
for cpu_num in 0 31 63; do
    cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    if [ -d "$cpu_dir" ]; then
        governor=$(cat "$cpu_dir/scaling_governor")
        min_freq=$(cat "$cpu_dir/scaling_min_freq")
        max_freq=$(cat "$cpu_dir/scaling_max_freq")
        cur_freq=$(cat "$cpu_dir/scaling_cur_freq")
        
        echo "  CPU${cpu_num}: gov=$governor, min=$((min_freq/1000))MHz, max=$((max_freq/1000))MHz, cur=$((cur_freq/1000))MHz"
    fi
done

echo ""
echo "=== Fix Complete ==="
