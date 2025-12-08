#!/bin/bash
#
# Real-time C-State Monitor
# Continuously displays C-state residency for all CPUs
#
# Usage: ./monitor_cstates.sh [interval_seconds]
#

INTERVAL=${1:-2}  # Default 2 seconds

print_header() {
    clear
    echo "=========================================="
    echo "C-State Residency Monitor"
    echo "Interval: ${INTERVAL}s | Press Ctrl+C to exit"
    echo "=========================================="
    echo ""
}

get_cstate_usage() {
    local cpu=$1

    echo "CPU $cpu:"

    for state_dir in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state*; do
        if [ -d "$state_dir" ]; then
            state_num=$(basename "$state_dir" | sed 's/state//')
            name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
            disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")
            time=$(cat "$state_dir/time" 2>/dev/null || echo "0")
            usage=$(cat "$state_dir/usage" 2>/dev/null || echo "0")

            # Convert time from microseconds to seconds for readability
            time_sec=$((time / 1000000))

            if [ "$disabled" = "0" ]; then
                status="✓"
            else
                status="✗"
            fi

            printf "  %-8s %-6s [%s] Time: %10ss  Usage: %10s\n" \
                "state$state_num" "$name" "$status" "$time_sec" "$usage"
        fi
    done
    echo ""
}

# Store initial values for delta calculation
declare -A prev_time
declare -A prev_usage

get_initial_values() {
    for state_dir in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
        if [ -d "$state_dir" ]; then
            state=$(basename "$state_dir")
            prev_time["$state"]=$(cat "$state_dir/time" 2>/dev/null || echo "0")
            prev_usage["$state"]=$(cat "$state_dir/usage" 2>/dev/null || echo "0")
        fi
    done
}

show_delta() {
    local cpu=$1

    echo "CPU $cpu C-State Activity (last ${INTERVAL}s):"

    for state_dir in /sys/devices/system/cpu/cpu${cpu}/cpuidle/state*; do
        if [ -d "$state_dir" ]; then
            state=$(basename "$state_dir")
            state_num=$(echo "$state" | sed 's/state//')
            name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
            disabled=$(cat "$state_dir/disable" 2>/dev/null || echo "N/A")

            curr_time=$(cat "$state_dir/time" 2>/dev/null || echo "0")
            curr_usage=$(cat "$state_dir/usage" 2>/dev/null || echo "0")

            delta_time=$((curr_time - prev_time["$state"]))
            delta_usage=$((curr_usage - prev_usage["$state"]))

            # Convert to milliseconds for better readability
            delta_time_ms=$((delta_time / 1000))

            # Calculate percentage of time in this state
            interval_us=$((INTERVAL * 1000000))
            if [ $interval_us -gt 0 ]; then
                percent=$((delta_time * 100 / interval_us))
            else
                percent=0
            fi

            if [ "$disabled" = "0" ]; then
                status="✓"
            else
                status="✗"
            fi

            # Highlight active states
            if [ $delta_usage -gt 0 ]; then
                marker="→"
            else
                marker=" "
            fi

            printf "  %s %-8s %-6s [%s] %3d%% | Time: %8sms | Entries: %6s\n" \
                "$marker" "state$state_num" "$name" "$status" "$percent" "$delta_time_ms" "$delta_usage"

            # Update previous values
            prev_time["$state"]=$curr_time
            prev_usage["$state"]=$curr_usage
        fi
    done
    echo ""
}

show_summary() {
    echo "Summary (All CPUs in C-state during last interval):"

    # Count CPUs in each state by checking which had activity
    local -A state_counts

    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu_num=$(basename "$cpu" | sed 's/cpu//')
        [ -d "$cpu/cpuidle" ] || continue

        # Find deepest state with recent activity
        deepest_active=""
        for state_dir in "$cpu"/cpuidle/state*; do
            if [ -d "$state_dir" ]; then
                state=$(basename "$state_dir")
                name=$(cat "$state_dir/name" 2>/dev/null || echo "N/A")
                curr_time=$(cat "$state_dir/time" 2>/dev/null || echo "0")

                # Simple heuristic: if time is increasing significantly, CPU was in this state
                if [ ${prev_time["$state"]+_} ]; then
                    delta=$((curr_time - prev_time["$state"]))
                    if [ $delta -gt 1000000 ]; then  # More than 1 second
                        deepest_active="$name"
                    fi
                fi
            fi
        done

        if [ -n "$deepest_active" ]; then
            state_counts["$deepest_active"]=$((${state_counts["$deepest_active"]:-0} + 1))
        fi
    done

    # Print summary
    for state in POLL C1 C1E C6; do
        count=${state_counts["$state"]:-0}
        if [ $count -gt 0 ]; then
            printf "  %-6s: %2d CPUs\n" "$state" "$count"
        fi
    done
    echo ""
}

main() {
    echo "Initializing C-state monitoring..."

    # Get initial values for CPU 0
    get_initial_values

    sleep 1

    while true; do
        print_header

        # Show detailed view for CPU 0 (representative)
        show_delta 0

        # Show summary for all CPUs
        show_summary

        echo "Monitoring... (Ctrl+C to stop)"

        sleep "$INTERVAL"
    done
}

main
