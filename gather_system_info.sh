#!/bin/bash

# System Information Gathering Script for Power Measurement Project
# Target: PowerEdge R450 - CentOS Stream 9
# Purpose: Collect CPU, IPMI, RAPL, and C-state information

set -u

OUTPUT_FILE="system_info_$(date +%Y%m%d_%H%M%S).txt"

echo "================================================"
echo "Power Measurement Project - System Information"
echo "================================================"
echo ""
echo "Gathering system information..."
echo "Output will be saved to: $OUTPUT_FILE"
echo ""

{
    echo "================================================"
    echo "SYSTEM INFORMATION REPORT"
    echo "Generated: $(date)"
    echo "================================================"
    echo ""

    # ============================================
    # System & OS Information
    # ============================================
    echo "=== SYSTEM & OS INFORMATION ==="
    echo ""

    echo "Hostname:"
    hostname
    echo ""

    echo "OS Release:"
    cat /etc/os-release
    echo ""

    echo "Kernel Version:"
    uname -a
    echo ""

    echo "DMI System Information:"
    if command -v dmidecode &> /dev/null; then
        sudo dmidecode -t system | grep -E "Manufacturer|Product Name|Serial Number"
    else
        echo "dmidecode not available"
    fi
    echo ""

    # ============================================
    # CPU Information
    # ============================================
    echo "=== CPU INFORMATION ==="
    echo ""

    echo "CPU Model:"
    lscpu | grep -E "Model name|Architecture|CPU\(s\)|Thread|Core|Socket|NUMA"
    echo ""

    echo "Detailed CPU Info:"
    lscpu
    echo ""

    echo "CPU Topology:"
    if [ -d /sys/devices/system/cpu ]; then
        echo "Total CPUs: $(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)"
        echo "Online CPUs: $(cat /sys/devices/system/cpu/online)"
        echo "Offline CPUs: $(cat /sys/devices/system/cpu/offline)"
    fi
    echo ""

    # ============================================
    # CPU Frequency Information
    # ============================================
    echo "=== CPU FREQUENCY INFORMATION ==="
    echo ""

    echo "Available Frequency Governors:"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
    else
        echo "cpufreq interface not available"
    fi
    echo ""

    echo "Current Frequency Governor (CPU 0):"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    else
        echo "cpufreq interface not available"
    fi
    echo ""

    echo "Available Frequencies (CPU 0):"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies ]; then
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
    else
        echo "scaling_available_frequencies not available"
    fi
    echo ""

    echo "Min/Max Frequencies (CPU 0):"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq ]; then
        echo "Min: $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq) kHz"
        echo "Max: $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) kHz"
    else
        echo "cpuinfo frequency not available"
    fi
    echo ""

    echo "Current Frequencies (all CPUs):"
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            if [ -f "$cpu" ]; then
                cpu_num=$(echo "$cpu" | grep -o "cpu[0-9]*" | grep -o "[0-9]*")
                freq=$(cat "$cpu")
                echo "CPU$cpu_num: $freq kHz"
            fi
        done
    else
        echo "cpufreq interface not available"
    fi
    echo ""

    # ============================================
    # C-State Information
    # ============================================
    echo "=== C-STATE INFORMATION ==="
    echo ""

    echo "Available C-states (CPU 0):"
    if [ -d /sys/devices/system/cpu/cpu0/cpuidle ]; then
        for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
            if [ -d "$state" ]; then
                state_name=$(basename "$state")
                name=$(cat "$state/name" 2>/dev/null || echo "N/A")
                desc=$(cat "$state/desc" 2>/dev/null || echo "N/A")
                latency=$(cat "$state/latency" 2>/dev/null || echo "N/A")
                disabled=$(cat "$state/disable" 2>/dev/null || echo "N/A")
                echo "  $state_name: $name - $desc (latency: $latency us, disabled: $disabled)"
            fi
        done
    else
        echo "cpuidle interface not available"
    fi
    echo ""

    # ============================================
    # RAPL Information
    # ============================================
    echo "=== RAPL (Running Average Power Limit) INFORMATION ==="
    echo ""

    echo "Checking MSR module:"
    if lsmod | grep -q msr; then
        echo "MSR module is loaded"
    else
        echo "MSR module is NOT loaded (required for RAPL)"
        echo "Try: sudo modprobe msr"
    fi
    echo ""

    echo "MSR device files:"
    ls -l /dev/cpu/*/msr 2>/dev/null || echo "MSR device files not found"
    echo ""

    echo "RAPL domains (via powercap):"
    if [ -d /sys/class/powercap ]; then
        for domain in /sys/class/powercap/intel-rapl/intel-rapl:*; do
            if [ -d "$domain" ]; then
                domain_name=$(basename "$domain")
                name=$(cat "$domain/name" 2>/dev/null || echo "N/A")
                if [ -f "$domain/energy_uj" ]; then
                    energy=$(cat "$domain/energy_uj")
                    echo "  $domain_name ($name): $energy uJ"
                else
                    echo "  $domain_name ($name): energy_uj not readable"
                fi
            fi
        done
    else
        echo "Powercap interface not available"
    fi
    echo ""

    echo "Checking turbostat availability:"
    if command -v turbostat &> /dev/null; then
        echo "turbostat is available"
        echo "Sample output (1 second):"
        sudo turbostat --quiet --show PkgWatt,CorWatt,RAMWatt --interval 1 sleep 1 2>/dev/null || echo "turbostat failed"
    else
        echo "turbostat not available (install: sudo dnf install kernel-tools)"
    fi
    echo ""

    # ============================================
    # IPMI Information
    # ============================================
    echo "=== IPMI INFORMATION ==="
    echo ""

    echo "Checking ipmitool availability:"
    if command -v ipmitool &> /dev/null; then
        echo "ipmitool is available"

        echo ""
        echo "IPMI Device Information:"
        sudo ipmitool mc info 2>&1 || echo "Failed to get IPMI MC info"

        echo ""
        echo "IPMI Sensor List (Power related):"
        sudo ipmitool sensor list | grep -iE "power|watt|curr" 2>&1 || echo "Failed to get sensor list"

        echo ""
        echo "Current Power Reading:"
        sudo ipmitool dcmi power reading 2>&1 || echo "DCMI power reading not available"
    else
        echo "ipmitool not available (install: sudo dnf install ipmitool)"
    fi
    echo ""

    # ============================================
    # Power Management Configuration
    # ============================================
    echo "=== POWER MANAGEMENT CONFIGURATION ==="
    echo ""

    echo "Intel P-state driver:"
    if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        echo "Intel P-state is active"
        echo "Status: $(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo 'N/A')"
        echo "No Turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo 'N/A')"
    else
        echo "Intel P-state not active (using acpi-cpufreq or other)"
    fi
    echo ""

    echo "Kernel Boot Parameters (power/cpu related):"
    cat /proc/cmdline | tr ' ' '\n' | grep -E "intel|cpu|idle|power|freq" || echo "No relevant parameters found"
    echo ""

    # ============================================
    # Installed Tools Check
    # ============================================
    echo "=== INSTALLED TOOLS CHECK ==="
    echo ""

    tools=("stress-ng" "ipmitool" "turbostat" "cpupower" "dmidecode" "lscpu" "numactl")
    for tool in "${tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            version=$($tool --version 2>&1 | head -1 || echo "unknown")
            echo "✓ $tool: installed ($version)"
        else
            echo "✗ $tool: NOT installed"
        fi
    done
    echo ""

    # ============================================
    # Summary
    # ============================================
    echo "=== SUMMARY ==="
    echo ""
    echo "Report generation complete."
    echo "Please review the output above for any missing tools or permissions."
    echo ""
    echo "Common next steps if issues found:"
    echo "  - Install missing tools: sudo dnf install ipmitool kernel-tools stress-ng"
    echo "  - Load MSR module: sudo modprobe msr"
    echo "  - Check IPMI/BMC configuration if ipmitool commands fail"
    echo ""

} | tee "$OUTPUT_FILE"

echo "================================================"
echo "Information saved to: $OUTPUT_FILE"
echo "================================================"
