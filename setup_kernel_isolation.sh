#!/bin/bash
#
# Kernel CPU Isolation Setup
# Adds isolcpus/nohz_full/rcu_nocbs to the kernel command line via grubby.
#
# Housekeeping: CPU 0 (NUMA0 package-0), CPU 72 (NUMA1 package-1)
# Isolated:     1-71,73-143,144-287 (286 physical cores, no HT on Xeon 6780E)
#
# Requires reboot to take effect.
#
# Usage: sudo ./setup_kernel_isolation.sh [apply|remove|status]
#

set -euo pipefail

ISOLATED_CPUS="1-71,73-143,144-287"
HOUSEKEEPING_CPUS="0,72"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Must run as root (use sudo)" >&2
        exit 1
    fi
}

check_grubby() {
    if ! command -v grubby &>/dev/null; then
        echo "ERROR: grubby not found. Install with: dnf install grubby" >&2
        exit 1
    fi
}

show_status() {
    echo "=========================================="
    echo "Kernel CPU Isolation Status"
    echo "=========================================="
    echo ""
    echo "Current kernel command line:"
    cat /proc/cmdline | tr ' ' '\n' | grep -E "isolcpus|nohz_full|rcu_nocbs" | sed 's/^/  /' || echo "  (no isolation parameters set)"
    echo ""
    echo "Default kernel args (grubby):"
    grubby --info=DEFAULT | grep "^args" | tr ' ' '\n' | grep -E "isolcpus|nohz_full|rcu_nocbs" | sed 's/^/  /' || echo "  (no isolation parameters set)"
    echo ""
    echo "Target isolated CPUs: $ISOLATED_CPUS"
    echo "Target housekeeping:  $HOUSEKEEPING_CPUS"
}

apply_isolation() {
    echo "=========================================="
    echo "Applying CPU Isolation to Kernel Cmdline"
    echo "=========================================="
    echo ""
    echo "Isolated CPUs : $ISOLATED_CPUS"
    echo "Housekeeping  : $HOUSEKEEPING_CPUS"
    echo ""

    # Remove any existing values first to avoid duplicates
    echo "Removing any existing isolation parameters..."
    grubby --update-kernel=ALL \
        --remove-args="isolcpus nohz_full rcu_nocbs"

    # Apply new values
    echo "Adding isolation parameters..."
    grubby --update-kernel=ALL \
        --args="isolcpus=domain,managed_irq,${ISOLATED_CPUS} nohz_full=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS}"

    echo ""
    echo "Updated kernel args:"
    grubby --info=DEFAULT | grep "^args" | tr ' ' '\n' | grep -E "isolcpus|nohz_full|rcu_nocbs" | sed 's/^/  /'

    echo ""
    echo "=========================================="
    echo "✓ Kernel command line updated."
    echo "  Reboot required to take effect."
    echo "  After reboot, verify with:"
    echo "    cat /proc/cmdline"
    echo "    cat /sys/devices/system/cpu/isolated"
    echo "=========================================="
}

remove_isolation() {
    echo "=========================================="
    echo "Removing CPU Isolation from Kernel Cmdline"
    echo "=========================================="
    echo ""

    grubby --update-kernel=ALL \
        --remove-args="isolcpus nohz_full rcu_nocbs"

    echo "✓ Isolation parameters removed."
    echo "  Reboot required to take effect."
}

case "${1:-}" in
    apply)
        check_root
        check_grubby
        apply_isolation
        ;;
    remove)
        check_root
        check_grubby
        remove_isolation
        ;;
    status)
        check_grubby
        show_status
        ;;
    *)
        echo "Usage: sudo $0 [apply|remove|status]"
        echo ""
        echo "  apply   Add isolcpus/nohz_full/rcu_nocbs to kernel cmdline (reboot required)"
        echo "  remove  Remove isolation parameters from kernel cmdline (reboot required)"
        echo "  status  Show current isolation parameters"
        exit 1
        ;;
esac
