#!/bin/bash

# Power Measurement CPU Frequency Toggle Script
# Toggles between minimum (800 MHz) and nominal (2000 MHz) frequencies
# Designed for Intel Xeon 6780E with 288 physical cores (no HT)
# NUMA 0: CPUs 0-71, 144-215
# NUMA 1: CPUs 72-143, 216-287

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

# Configuration
MIN_FREQ_KHZ=800000    # 800 MHz
NOMINAL_FREQ_KHZ=2000000 # 2000 MHz (base frequency for Xeon 6780E)
CPU_COUNT=288          # Number of logical CPUs (0-287)

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)"
        exit 1
    fi
}

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [min|nominal|status]

Power Measurement CPU Frequency Toggle Script
For Intel Xeon 6780E with intel_cpufreq driver (288 logical CPUs)

Arguments:
    min       Set all CPUs to minimum frequency (800 MHz)
    nominal   Set all CPUs to nominal frequency (2000 MHz)
    status    Show current CPU frequency status

Examples:
    sudo $SCRIPT_NAME min        # Set to 800 MHz for power measurement
    sudo $SCRIPT_NAME nominal    # Set to 2000 MHz for baseline
    sudo $SCRIPT_NAME status     # Check current settings
EOF
    exit 1
}

disable_turbo() {
    echo "Disabling turbo boost..."
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
        echo "  ✓ Turbo disabled"
    else
        echo "  ! Turbo control not available"
    fi
}

set_all_cpus_governor() {
    local governor=$1
    echo "Setting all CPUs to $governor governor..."
    
    for cpu_num in $(seq 0 $((CPU_COUNT-1))); do
        cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}"
        governor_file="$cpu_dir/cpufreq/scaling_governor"
        
        if [ -f "$governor_file" ]; then
            echo "$governor" > "$governor_file"
        fi
    done
    
    echo "  ✓ Governor set to $governor for all CPUs"
}

set_all_cpus_frequency() {
    local target_freq=$1
    local freq_mhz=$((target_freq / 1000))
    local mode_name=$2
    
    echo "Setting all CPUs to ${freq_mhz} MHz ($mode_name frequency)..."
    
    for cpu_num in $(seq 0 $((CPU_COUNT-1))); do
        cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}"
        cpufreq_dir="$cpu_dir/cpufreq"
        
        if [ -d "$cpufreq_dir" ]; then
            # Set frequency limits
            echo "$target_freq" > "$cpufreq_dir/scaling_min_freq"
            echo "$target_freq" > "$cpufreq_dir/scaling_max_freq"
            
            # Set current frequency if userspace governor
            if [ -f "$cpufreq_dir/scaling_setspeed" ]; then
                echo "$target_freq" > "$cpufreq_dir/scaling_setspeed"
            fi
        fi
    done
    
    echo "  ✓ All CPUs set to ${freq_mhz} MHz"
}

show_status() {
    echo "=========================================="
    echo "CPU Frequency Status"
    echo "=========================================="
    echo ""
    
    # Show driver info
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]; then
        echo "Driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)"
    fi
    
    if [ -f /sys/devices/system/cpu/intel_pstate/status ]; then
        echo "Intel P-state: $(cat /sys/devices/system/cpu/intel_pstate/status)"
    fi
    
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo "Turbo Boost: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
    fi
    
    echo ""
    
    # Sample a few CPUs across both NUMA nodes
    sample_cpus="0 71 143 215 287"
    
    printf "%-6s %-12s %-10s %-10s %-10s\n" "CPU" "Governor" "Min" "Max" "Current"
    printf "%-6s %-12s %-10s %-10s %-10s\n" "---" "--------" "---" "---" "-------"
    
    for cpu_num in $sample_cpus; do
        cpu_dir="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
        
        if [ -d "$cpu_dir" ]; then
            governor=$(cat "$cpu_dir/scaling_governor" 2>/dev/null || echo "N/A")
            min_freq=$(cat "$cpu_dir/scaling_min_freq" 2>/dev/null || echo "0")
            max_freq=$(cat "$cpu_dir/scaling_max_freq" 2>/dev/null || echo "0")
            cur_freq=$(cat "$cpu_dir/scaling_cur_freq" 2>/dev/null || echo "0")
            
            printf "%-6s %-12s %6d MHz %6d MHz %6d MHz\n" \
                "cpu${cpu_num}" "$governor" "$((min_freq/1000))" "$((max_freq/1000))" "$((cur_freq/1000))"
        fi
    done
    
    echo ""
}

main() {
    check_root
    
    if [ $# -ne 1 ]; then
        usage
    fi
    
    case "$1" in
        min|minimum)
            echo "=========================================="
            echo "Setting CPUs to MINIMUM Frequency"
            echo "=========================================="
            echo ""
            
            disable_turbo
            set_all_cpus_governor "userspace"
            set_all_cpus_frequency "$MIN_FREQ_KHZ" "minimum"
            
            echo ""
            echo "✓ All CPUs set to 800 MHz (minimum frequency)"
            echo "✓ Turbo boost disabled"
            echo "✓ Ready for power measurement"
            ;;
        
        nominal|base|2000)
            echo "=========================================="
            echo "Setting CPUs to NOMINAL Frequency"
            echo "=========================================="
            echo ""
            
            disable_turbo
            set_all_cpus_governor "userspace"
            set_all_cpus_frequency "$NOMINAL_FREQ_KHZ" "nominal"
            
            echo ""
            echo "✓ All CPUs set to 2000 MHz (nominal frequency)"
            echo "✓ Turbo boost disabled"
            echo "✓ Ready for baseline measurement"
            ;;
        
        status|check|info)
            show_status
            ;;
        
        *)
            echo "ERROR: Invalid argument '$1'"
            echo ""
            usage
            ;;
    esac
}

main "$@"
