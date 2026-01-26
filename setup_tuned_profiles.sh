#!/bin/bash
#
# Setup Tuned Profiles for Power Measurement Tests
#
# This script creates tuned profiles for all test scenarios:
# - Test 1: Idle with deep C-state (nominal and min frequency)
# - Test 2: Idle with C1 state (nominal and min frequency)
# - Test 3: CPU stress test (nominal and min frequency)
# - Test 4: DPDK workload (nominal and min frequency)
#
# Supports both Intel and AMD platforms with automatic detection.
#
# Usage: sudo ./setup_tuned_profiles.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNED_BASE_DIR="/etc/tuned"

# Detect platform and set appropriate frequencies
detect_platform() {
    local vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    local driver=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")

    if [ "$vendor" = "AuthenticAMD" ]; then
        PLATFORM="AMD"
        # Try to get frequencies from amd-pstate if available
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_lowest_nonlinear_freq ]; then
            # Use lowest non-linear freq as min (more efficient than absolute min)
            MIN_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_lowest_nonlinear_freq 2>/dev/null || echo "1800000")
        else
            MIN_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo "400000")
        fi
        # Get nominal frequency
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_nominal_freq ]; then
            NOMINAL_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/amd_pstate_nominal_freq 2>/dev/null || echo "2250000")
        else
            # Fallback: use scaling_max_freq as approximation
            NOMINAL_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "2250000")
        fi
        echo "Detected AMD platform (driver: $driver)"
    else
        PLATFORM="Intel"
        MIN_FREQ=800000
        NOMINAL_FREQ=2300000
        echo "Detected Intel platform (driver: $driver)"
    fi

    echo "  Nominal frequency: $((NOMINAL_FREQ / 1000)) MHz"
    echo "  Minimum frequency: $((MIN_FREQ / 1000)) MHz"
    echo ""
}

# Detect CPU count and calculate isolated cores
# Keep 2 physical cores (and their SMT siblings) for kernel housekeeping, isolate all others
# On multi-socket systems, keeps cores from first socket only for NUMA locality
detect_cpus() {
    local num_cpus=$(nproc)

    echo "  Total logical CPUs: $num_cpus"

    # Get housekeeping CPUs: physical cores 0 and 1 plus their SMT siblings
    # Use thread_siblings_list which shows all CPUs sharing the same physical core
    local housekeeping_list=""

    # Get siblings of CPU 0 (physical core 0)
    if [ -f /sys/devices/system/cpu/cpu0/topology/thread_siblings_list ]; then
        local siblings0=$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)
        housekeeping_list="$siblings0"
    else
        housekeeping_list="0"
    fi

    # Get siblings of CPU 1 (physical core 1)
    if [ -f /sys/devices/system/cpu/cpu1/topology/thread_siblings_list ]; then
        local siblings1=$(cat /sys/devices/system/cpu/cpu1/topology/thread_siblings_list)
        housekeeping_list="$housekeeping_list,$siblings1"
    else
        housekeeping_list="$housekeeping_list,1"
    fi

    # Parse housekeeping list into a set for easy lookup
    # Expand any ranges (e.g., "0-1" -> "0,1")
    local housekeeping_expanded=$(echo "$housekeeping_list" | tr ',' '\n' | while read range; do
        if [[ "$range" == *-* ]]; then
            local start=${range%-*}
            local end=${range#*-}
            seq $start $end
        else
            echo "$range"
        fi
    done | sort -n | uniq)

    # Build isolated list as complement
    local isolated_list=""
    for cpu in $(seq 0 $((num_cpus - 1))); do
        if ! echo "$housekeeping_expanded" | grep -qx "$cpu"; then
            if [ -z "$isolated_list" ]; then
                isolated_list="$cpu"
            else
                isolated_list="$isolated_list,$cpu"
            fi
        fi
    done

    # Compact lists into ranges for kernel parameters
    compact_cpu_list() {
        echo "$1" | tr ',' '\n' | sort -n | \
            awk 'NR==1{first=last=$1;next} $1==last+1{last=$1;next} {print first==last?first:first"-"last; first=last=$1} END{print first==last?first:first"-"last}' | \
            paste -sd,
    }

    HOUSEKEEPING_CPUS=$(compact_cpu_list "$(echo "$housekeeping_expanded" | tr '\n' ',')")
    ISOLATED_CPUS=$(compact_cpu_list "$isolated_list")

    # Count physical cores being used
    local hk_physical=2
    local isolated_physical=$(( (num_cpus - $(echo "$housekeeping_expanded" | wc -l)) / $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list | tr ',' '\n' | wc -l) ))

    echo "  Housekeeping: $HOUSEKEEPING_CPUS (${hk_physical} physical cores)"
    echo "  Isolated: $ISOLATED_CPUS (${isolated_physical} physical cores)"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

# Ensure amd-pstate is in passive mode for frequency control
setup_amd_pstate_passive() {
    if [ "$PLATFORM" = "AMD" ]; then
        local status_file="/sys/devices/system/cpu/amd_pstate/status"
        if [ -f "$status_file" ]; then
            local current_status=$(cat "$status_file")
            if [ "$current_status" != "passive" ]; then
                echo "Switching amd-pstate to passive mode for frequency control..."
                echo passive > "$status_file" 2>/dev/null || {
                    echo "WARNING: Could not switch to passive mode. Fixed frequencies may not work."
                    echo "         Add 'amd_pstate=passive' to kernel boot parameters for best results."
                }
            fi
        fi
    fi
}

create_profile_test1_c6_nominal() {
    local profile_name="powertest-1-c6-nominal"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((NOMINAL_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 1: Idle with deep C-state, Nominal frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
#

[main]
summary=Power Test 1: Idle deep sleep @ ${freq_mhz}MHz

[cpu]
governor=userspace
energy_perf_bias=powersave

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

    # Ensure amd-pstate is in passive mode for frequency control
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to nominal (${NOMINAL_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Enable all C-states (deep sleep)
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    # Re-enable turbo/boost
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    return 0
}

process \$@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name (${freq_mhz} MHz)"
}

create_profile_test1_c6_min() {
    local profile_name="powertest-1-c6-min"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((MIN_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 1: Idle with deep C-state, Minimum frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
#

[main]
summary=Power Test 1: Idle deep sleep @ ${freq_mhz}MHz

[cpu]
governor=userspace
energy_perf_bias=powersave

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

    # Ensure amd-pstate is in passive mode for frequency control
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to minimum (${MIN_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Enable all C-states (deep sleep)
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    return 0
}

process \$@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name"
}

create_profile_test2_c1_nominal() {
    local profile_name="powertest-2-c1-nominal"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((NOMINAL_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 2: Idle with C1 state only, Nominal frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
#

[main]
summary=Power Test 2: Idle C1 @ ${freq_mhz}MHz

[cpu]
governor=userspace
energy_perf_bias=performance

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

    # Ensure amd-pstate is in passive mode for frequency control
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to nominal (${NOMINAL_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Disable deeper C-states, keep only POLL and C1
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu/cpuidle" ] || continue
        # Enable POLL (state0) and C1 (state1)
        [ -f "\$cpu/cpuidle/state0/disable" ] && echo 0 > "\$cpu/cpuidle/state0/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state1/disable" ] && echo 0 > "\$cpu/cpuidle/state1/disable" 2>/dev/null || true
        # Disable state2+ (C2/C1E/C6 depending on platform)
        [ -f "\$cpu/cpuidle/state2/disable" ] && echo 1 > "\$cpu/cpuidle/state2/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state3/disable" ] && echo 1 > "\$cpu/cpuidle/state3/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state4/disable" ] && echo 1 > "\$cpu/cpuidle/state4/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    # Re-enable all C-states
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done
    return 0
}

process $@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name"
}

create_profile_test2_c1_min() {
    local profile_name="powertest-2-c1-min"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((MIN_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 2: Idle with C1 state only, Minimum frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
#

[main]
summary=Power Test 2: Idle C1 @ ${freq_mhz}MHz

[cpu]
governor=userspace
energy_perf_bias=performance

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

    # Ensure amd-pstate is in passive mode for frequency control
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to minimum (${MIN_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Disable deeper C-states, keep only POLL and C1
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu/cpuidle" ] || continue
        [ -f "\$cpu/cpuidle/state0/disable" ] && echo 0 > "\$cpu/cpuidle/state0/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state1/disable" ] && echo 0 > "\$cpu/cpuidle/state1/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state2/disable" ] && echo 1 > "\$cpu/cpuidle/state2/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state3/disable" ] && echo 1 > "\$cpu/cpuidle/state3/disable" 2>/dev/null || true
        [ -f "\$cpu/cpuidle/state4/disable" ] && echo 1 > "\$cpu/cpuidle/state4/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done
    return 0
}

process $@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name"
}

create_profile_test3_stress_nominal() {
    local profile_name="powertest-3-stress-nominal"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((NOMINAL_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 3: CPU Stress test, Nominal frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
#

[main]
summary=Power Test 3: Stress @ ${freq_mhz}MHz

[cpu]
governor=userspace
energy_perf_bias=performance

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to nominal (${NOMINAL_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Enable all C-states
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    return 0
}

process \$@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name (${freq_mhz} MHz)"
}

create_profile_test3_stress_min() {
    local profile_name="powertest-3-stress-min"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((MIN_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 3: CPU Stress test, Minimum frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
#

[main]
summary=Power Test 3: Stress @ ${freq_mhz}MHz

[cpu]
governor=userspace
energy_perf_bias=performance

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to minimum (${MIN_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Enable all C-states
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    return 0
}

process \$@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name (${freq_mhz} MHz)"
}

create_profile_test4_dpdk_nominal() {
    local profile_name="powertest-4-dpdk-nominal"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((NOMINAL_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 4: DPDK workload, Nominal frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
# With CPU isolation (housekeeping: ${HOUSEKEEPING_CPUS}, isolated: ${ISOLATED_CPUS})
#

[main]
summary=Power Test 4: DPDK @ ${freq_mhz}MHz
include=cpu-partitioning

[cpu]
governor=userspace
energy_perf_bias=performance

[variables]
# Keep CPUs ${HOUSEKEEPING_CPUS} for housekeeping, isolate ${ISOLATED_CPUS} for DPDK
isolated_cores=${ISOLATED_CPUS}

[script]
script=\${i:PROFILE_DIR}/script.sh

[bootloader]
# Requires reboot to take effect
cmdline_isolation=nohz_full=${ISOLATED_CPUS} isolcpus=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS}
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to nominal (${NOMINAL_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${NOMINAL_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Enable all C-states
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    return 0
}

process \$@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name (${freq_mhz} MHz)"
}

create_profile_test4_dpdk_min() {
    local profile_name="powertest-4-dpdk-min"
    local profile_dir="$TUNED_BASE_DIR/$profile_name"
    local freq_mhz=$((MIN_FREQ / 1000))

    echo "Creating profile: $profile_name"
    mkdir -p "$profile_dir"

    cat > "$profile_dir/tuned.conf" <<EOF
#
# Test 4: DPDK workload, Minimum frequency (${freq_mhz} MHz)
# Platform: $PLATFORM
# With CPU isolation (housekeeping: ${HOUSEKEEPING_CPUS}, isolated: ${ISOLATED_CPUS})
#

[main]
summary=Power Test 4: DPDK @ ${freq_mhz}MHz
include=cpu-partitioning

[cpu]
governor=userspace
energy_perf_bias=performance

[variables]
# Keep CPUs ${HOUSEKEEPING_CPUS} for housekeeping, isolate ${ISOLATED_CPUS} for DPDK
isolated_cores=${ISOLATED_CPUS}

[script]
script=\${i:PROFILE_DIR}/script.sh

[bootloader]
# Requires reboot to take effect
cmdline_isolation=nohz_full=${ISOLATED_CPUS} isolcpus=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS}
EOF

    cat > "$profile_dir/script.sh" <<EOF
#!/bin/bash
. /usr/lib/tuned/functions

start() {
    # Disable turbo/boost
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    echo passive > /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || true

    # Set frequency to minimum (${MIN_FREQ} kHz = ${freq_mhz} MHz)
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "\$cpu_dir/cpufreq" ] || continue
        echo userspace > "\$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_min_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_max_freq" 2>/dev/null || true
        echo ${MIN_FREQ} > "\$cpu_dir/cpufreq/scaling_setspeed" 2>/dev/null || true
    done

    # Enable all C-states
    for state_dir in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*; do
        [ -d "\$state_dir" ] || continue
        echo 0 > "\$state_dir/disable" 2>/dev/null || true
    done

    return 0
}

stop() {
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    return 0
}

process \$@
EOF

    chmod +x "$profile_dir/script.sh"
    echo "  ✓ Created $profile_name (${freq_mhz} MHz)"
}

main() {
    echo "========================================="
    echo "Setting up Tuned Profiles"
    echo "========================================="
    echo ""

    check_root

    # Detect platform and set frequencies
    detect_platform

    # Detect CPU topology for isolation
    detect_cpus

    # Setup AMD P-state passive mode if needed
    setup_amd_pstate_passive

    # Check if tuned is installed
    if ! command -v tuned-adm &>/dev/null; then
        echo "ERROR: tuned is not installed" >&2
        echo "Install it with: sudo dnf install tuned" >&2
        exit 1
    fi

    echo "Creating 8 tuned profiles for power measurement tests..."
    echo ""

    # Test 1: Idle deep C-state
    create_profile_test1_c6_nominal
    create_profile_test1_c6_min

    # Test 2: Idle C1
    create_profile_test2_c1_nominal
    create_profile_test2_c1_min

    # Test 3: Stress
    create_profile_test3_stress_nominal
    create_profile_test3_stress_min

    # Test 4: DPDK
    create_profile_test4_dpdk_nominal
    create_profile_test4_dpdk_min

    local nominal_mhz=$((NOMINAL_FREQ / 1000))
    local min_mhz=$((MIN_FREQ / 1000))

    echo ""
    echo "========================================="
    echo "✓ All profiles created successfully!"
    echo "========================================="
    echo ""
    echo "Platform: $PLATFORM"
    echo "Available profiles:"
    echo "  Test 1 (Idle deep sleep):"
    echo "    - powertest-1-c6-nominal  (${nominal_mhz} MHz)"
    echo "    - powertest-1-c6-min      (${min_mhz} MHz)"
    echo ""
    echo "  Test 2 (Idle C1):"
    echo "    - powertest-2-c1-nominal  (${nominal_mhz} MHz)"
    echo "    - powertest-2-c1-min      (${min_mhz} MHz)"
    echo ""
    echo "  Test 3 (Stress):"
    echo "    - powertest-3-stress-nominal  (${nominal_mhz} MHz)"
    echo "    - powertest-3-stress-min      (${min_mhz} MHz)"
    echo ""
    echo "  Test 4 (DPDK with CPU isolation):"
    echo "    - powertest-4-dpdk-nominal  (${nominal_mhz} MHz)"
    echo "    - powertest-4-dpdk-min      (${min_mhz} MHz)"
    echo "    Housekeeping CPUs: ${HOUSEKEEPING_CPUS}"
    echo "    Isolated CPUs: ${ISOLATED_CPUS}"
    echo ""
    echo "Usage:"
    echo "  tuned-adm profile powertest-1-c6-nominal"
    echo "  tuned-adm active"
    echo ""
    echo "Note: Test 4 profiles require reboot for CPU isolation to take effect"
    echo "      Kernel params: isolcpus=${ISOLATED_CPUS} nohz_full=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS}"
}

main "$@"
