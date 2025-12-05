#!/bin/bash
#
# Script for Test 1 C6 Nominal profile
# Sets CPU frequency to 2300 MHz and enables C6 states
#

. /usr/lib/tuned/functions

NOMINAL_FREQ=2300000  # 2300 MHz in kHz

start() {
    # Disable turbo
    [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ] && \
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

    # Set frequency for all CPUs
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_setspeed; do
        [ -f "$cpu" ] && echo $NOMINAL_FREQ > "$cpu"
    done

    # Ensure all C-states are enabled
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
        [ -f "$state" ] && echo 0 > "$state"
    done

    return 0
}

stop() {
    # Restore defaults (enable turbo)
    [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ] && \
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo

    return 0
}

process $@
