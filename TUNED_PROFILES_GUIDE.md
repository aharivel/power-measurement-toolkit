# Tuned Profiles for Power Measurement Tests

This guide explains how to use tuned profiles for consistent, reproducible power measurement tests.

## Why Tuned Profiles?

Tuned profiles provide:
- **Production-grade configuration** - Official Red Hat/CentOS method
- **Comprehensive settings** - Handles CPU frequency, C-states, isolation, IRQ affinity
- **Persistence** - Configuration survives service restarts (but not reboots for bootloader params)
- **Validation** - Tuned verifies settings are applied correctly

## Overview

We've created **8 tuned profiles** for power measurement tests:

| Profile Name | Test | Frequency | C-State | Description |
|--------------|------|-----------|---------|-------------|
| `powertest-1-c6-nominal` | Test 1 | 2300 MHz | C6 enabled | Idle with deep sleep |
| `powertest-1-c6-min` | Test 1 | 800 MHz | C6 enabled | Idle with deep sleep |
| `powertest-2-c1-nominal` | Test 2 | 2300 MHz | C1 only | Idle with shallow sleep |
| `powertest-2-c1-min` | Test 2 | 800 MHz | C1 only | Idle with shallow sleep |
| `powertest-3-stress-nominal` | Test 3 | 2300 MHz | All enabled | CPU stress test |
| `powertest-3-stress-min` | Test 3 | 800 MHz | All enabled | CPU stress test |
| `powertest-4-dpdk-nominal` | Test 4 | 2300 MHz | All enabled | DPDK with CPU isolation |
| `powertest-4-dpdk-min` | Test 4 | 800 MHz | All enabled | DPDK with CPU isolation |

## Installation

### 1. Install Tuned (if not already installed)
```bash
sudo dnf install tuned
sudo systemctl enable --now tuned
```

### 2. Create Power Test Profiles
```bash
sudo ./setup_tuned_profiles.sh
```

This creates all 8 profiles in `/etc/tuned/`.

### 3. Verify Installation
```bash
./manage_test_profile.sh list
```

You should see all 8 `powertest-*` profiles listed.

## Usage

### Basic Commands

**List available profiles:**
```bash
./manage_test_profile.sh list
```

**Show active profile:**
```bash
./manage_test_profile.sh active
```

**Activate a profile:**
```bash
sudo ./manage_test_profile.sh set powertest-1-c6-nominal
```

**Verify configuration:**
```bash
./manage_test_profile.sh verify
```

**Restore to default:**
```bash
sudo ./manage_test_profile.sh restore
```

## Running Tests

### Test 1: Idle with C6 State

**Nominal frequency (2300 MHz):**
```bash
# Activate profile
sudo ./manage_test_profile.sh set powertest-1-c6-nominal

# Verify configuration
./manage_test_profile.sh verify

# Run power monitoring for 5 minutes
sudo ./power_monitor.py --duration 300 --output test1_c6_nominal.csv

# Let system idle during monitoring
```

**Minimum frequency (800 MHz):**
```bash
sudo ./manage_test_profile.sh set powertest-1-c6-min
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test1_c6_min.csv
```

### Test 2: Idle with C1 State

**Nominal frequency:**
```bash
sudo ./manage_test_profile.sh set powertest-2-c1-nominal
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test2_c1_nominal.csv
```

**Minimum frequency:**
```bash
sudo ./manage_test_profile.sh set powertest-2-c1-min
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test2_c1_min.csv
```

### Test 3: CPU Stress Test

**Nominal frequency:**
```bash
sudo ./manage_test_profile.sh set powertest-3-stress-nominal
./manage_test_profile.sh verify

# Terminal 1: Start power monitoring
sudo ./power_monitor.py --duration 300 --output test3_stress_nominal.csv

# Terminal 2: Run stress test
stress-ng --cpu 40 --timeout 300s
```

**Minimum frequency:**
```bash
sudo ./manage_test_profile.sh set powertest-3-stress-min
./manage_test_profile.sh verify

# Terminal 1:
sudo ./power_monitor.py --duration 300 --output test3_stress_min.csv

# Terminal 2:
stress-ng --cpu 40 --timeout 300s
```

### Test 4: DPDK Application

**Important:** Test 4 profiles include CPU isolation which requires a **reboot** to take effect.

**Nominal frequency:**
```bash
# Activate profile (requires reboot for isolation)
sudo ./manage_test_profile.sh set powertest-4-dpdk-nominal

# Reboot the system
sudo reboot

# After reboot, verify isolation is active
./manage_test_profile.sh verify
grep isolcpus /proc/cmdline

# Run your DPDK application on isolated cores (4-19)
# Example:
# taskset -c 4-19 ./your-dpdk-app

# In another terminal, monitor power:
sudo ./power_monitor.py --duration 300 --output test4_dpdk_nominal.csv
```

**Minimum frequency:**
```bash
sudo ./manage_test_profile.sh set powertest-4-dpdk-min
sudo reboot

# After reboot:
./manage_test_profile.sh verify
# Run DPDK app and power monitoring
```

## Understanding the Profiles

### Test 1 & 2 Profiles (Idle Tests)

These profiles configure:
- CPU frequency pinning (nominal or min)
- C-state configuration (C6 enabled vs C1 only)
- Turbo boost disabled
- Userspace governor for fixed frequency

**No reboot required** - changes take effect immediately.

### Test 3 Profiles (Stress Test)

These profiles configure:
- CPU frequency pinning (nominal or min)
- All C-states enabled
- Optimized for throughput
- Turbo boost disabled

**No reboot required** - changes take effect immediately.

### Test 4 Profiles (DPDK)

These profiles configure:
- CPU frequency pinning (nominal or min)
- CPU isolation (CPUs 4-19 isolated for DPDK)
- Kernel parameters: `isolcpus`, `nohz_full`, `rcu_nocbs`
- Based on `cpu-partitioning` profile

**Reboot required** - kernel parameters only apply after reboot.

## CPU Isolation Details (Test 4)

The Test 4 profiles isolate CPUs 4-19 for DPDK workloads:

- **CPUs 0-3**: Housekeeping (OS, monitoring tool, SSH, etc.)
- **CPUs 4-19**: Isolated for DPDK application (physical cores 4-19, thread 0)
- **CPUs 20-39**: Available but not isolated (hyperthreads)

You can modify the isolated cores by editing `/etc/tuned/powertest-4-dpdk-*/tuned.conf` and changing the `isolated_cores` variable.

## Troubleshooting

### Profile doesn't apply

```bash
# Check tuned service status
sudo systemctl status tuned

# Restart tuned
sudo systemctl restart tuned

# Reapply profile
sudo tuned-adm profile powertest-X-Y-Z
```

### Frequency not changing

```bash
# Check cpufreq interface
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq

# Check tuned logs
sudo journalctl -u tuned -n 50
```

### C-states not applying

```bash
# Check cpuidle interface
for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    echo "$(basename $state): $(cat $state/name) - disabled=$(cat $state/disable)"
done
```

### Isolation not working (Test 4)

```bash
# Check kernel parameters (requires reboot to take effect)
cat /proc/cmdline | grep isolcpus

# If not present, reboot required:
sudo reboot
```

## Comparison: Tuned Profiles vs Manual Scripts

| Feature | Tuned Profiles | Manual Scripts |
|---------|----------------|----------------|
| Persistence | Yes (services) | No |
| Reboot for isolation | Yes (kernel params) | No (cgroups only) |
| Production-ready | ✓ | - |
| Quick switching | Moderate | Fast |
| Comprehensiveness | High | Basic |
| Recommended for | Final testing, production | Quick iteration |

**Recommendation:** Use tuned profiles for reproducible, production-grade testing.

## After Testing

Always restore to default profile:

```bash
sudo ./manage_test_profile.sh restore
```

Or manually:
```bash
sudo tuned-adm profile balanced
```

## File Locations

- Profiles: `/etc/tuned/powertest-*/`
- Setup script: `./setup_tuned_profiles.sh`
- Management script: `./manage_test_profile.sh`
- Tuned logs: `journalctl -u tuned`

## Notes

- All profiles disable turbo boost for consistent measurements
- Profiles use `userspace` governor to pin frequency precisely
- Test 1-3 profiles work without reboot
- Test 4 profiles require reboot for isolation
- You can customize profiles by editing `/etc/tuned/powertest-*/tuned.conf`
