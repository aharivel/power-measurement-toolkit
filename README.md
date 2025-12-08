# Power Measurement Tool Suite

Tools for measuring CPU frequency impact on power consumption for Dell PowerEdge R450 server.

## Quick Start

```bash
# 1. Install tools
sudo dnf install ipmitool stress-ng numactl kernel-tools tuned

# 2. Switch to passive mode (CRITICAL!)
echo passive | sudo tee /sys/devices/system/cpu/intel_pstate/status

# 3. Validate setup
./validate_setup.sh

# 4. Install tuned profiles
sudo ./setup_tuned_profiles.sh

# 5. Run a test
sudo ./manage_test_profile.sh set powertest-1-c6-nominal
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test1_c6_nominal.csv
```

## Components

### 1. System Information Gatherer (`gather_system_info.sh`)

Collects comprehensive system information including CPU specs, frequency settings, C-states, RAPL, and IPMI availability.

**Usage:**
```bash
./gather_system_info.sh
```

**Output:** Creates `system_info_<timestamp>.txt` with full system details.

### 2. CPU Configuration - Tuned Profiles (Recommended)

**Production-grade configuration using Red Hat/CentOS tuned system.**

We provide **two approaches** for CPU configuration:
1. **Tuned Profiles** (Recommended) - Production-grade, persistent, comprehensive
2. **Manual Scripts** (Quick testing) - Fast iteration, no reboot needed

#### Tuned Profiles Setup

**Install profiles:**
```bash
sudo ./setup_tuned_profiles.sh
```

This creates 8 tuned profiles for all test scenarios (see `TUNED_PROFILES_GUIDE.md` for details).

**Usage:**
```bash
# List profiles
./manage_test_profile.sh list

# Activate a profile
sudo ./manage_test_profile.sh set powertest-1-c6-nominal

# Verify configuration
./manage_test_profile.sh verify

# Restore defaults
sudo ./manage_test_profile.sh restore
```

**Available Profiles:**
- `powertest-1-c6-nominal` / `powertest-1-c6-min` - Idle with C6 @ 2300MHz/800MHz
- `powertest-2-c1-nominal` / `powertest-2-c1-min` - Idle with C1 @ 2300MHz/800MHz
- `powertest-3-stress-nominal` / `powertest-3-stress-min` - Stress @ 2300MHz/800MHz
- `powertest-4-dpdk-nominal` / `powertest-4-dpdk-min` - DPDK @ 2300MHz/800MHz (requires reboot)

See **[TUNED_PROFILES_GUIDE.md](TUNED_PROFILES_GUIDE.md)** for complete documentation.

---

### 2b. CPU Configuration - Manual Scripts (Alternative)

Simple scripts for quick CPU configuration during testing.

#### `set_cpu_freq.sh` - CPU Frequency Control

Pin CPU frequency to nominal (base 2300 MHz) or minimum (800 MHz) for consistent measurements.

**Usage:**
```bash
sudo ./set_cpu_freq.sh nominal    # Set to 2300 MHz (base/nominal)
sudo ./set_cpu_freq.sh min        # Set to 800 MHz (min)
```

**What it does:**
- Sets userspace governor for manual frequency control
- Pins all CPUs to specified frequency (nominal = 2300 MHz base, NOT 3400 MHz turbo)
- Disables turbo boost for consistent measurements

#### `set_cstates.sh` - C-State Configuration

Configure CPU idle states (C1 vs C6) for different test scenarios.

**Usage:**
```bash
sudo ./set_cstates.sh c6     # Enable C6 deep sleep (Test 1)
sudo ./set_cstates.sh c1     # Limit to C1 shallow sleep (Test 2)
sudo ./set_cstates.sh all    # Enable all C-states (default)
```

**What it does:**
- Test 1 (c6): Enables all C-states including C6 (deep sleep, max power saving)
- Test 2 (c1): Disables C1E and C6, keeps only C1 (shallow sleep, fast wake-up)

#### `manage_cpu_isolation.sh` - CPU Isolation

Isolate CPUs for dedicated workloads (useful for DPDK test).

**Usage:**
```bash
sudo ./manage_cpu_isolation.sh status          # Show current status
sudo ./manage_cpu_isolation.sh topology        # Show CPU topology
sudo ./manage_cpu_isolation.sh isolate 4-39    # Isolate CPUs 4-39
sudo ./manage_cpu_isolation.sh restore         # Restore normal scheduling
```

**What it does:**
- Creates housekeeping and isolated CPU sets using cgroups
- Moves all processes to housekeeping CPUs
- Leaves isolated CPUs free for dedicated workload

#### `verify_config.sh` - Configuration Verification

Verify all CPU settings before running tests.

**Usage:**
```bash
./verify_config.sh              # Quick summary
./verify_config.sh --detailed   # Full per-CPU details
```

**Output:**
- CPU frequency settings
- C-state configuration
- Turbo boost status
- Isolation status
- Power measurement interfaces
- Summary with warnings

#### `reset_to_defaults.sh` - Reset to Defaults

Restore system to default configuration.

**Usage:**
```bash
sudo ./reset_to_defaults.sh         # Reset with confirmation
sudo ./reset_to_defaults.sh --force # Skip confirmation
```

**What it does:**
- Restores default frequency governor (schedutil/performance)
- Enables all C-states
- Removes CPU isolation
- Enables turbo boost

### 3. Power Monitor (`power_monitor.py`)

Real-time power consumption monitoring tool that reads from:
- **IPMI**: System-level power consumption (Watts)
- **RAPL**: CPU package power consumption (Watts)

**Features:**
- Configurable sampling interval
- CSV output for data analysis
- Real-time console display
- Handles RAPL counter rollover
- Graceful Ctrl+C handling

**Requirements:**
- Root/sudo access (for IPMI and RAPL)
- `ipmitool` installed
- MSR module loaded
- RAPL interface available at `/sys/class/powercap/intel-rapl/`

**Usage:**

```bash
# Monitor for 60 seconds with 1-second interval, save to CSV
sudo ./power_monitor.py --duration 60 --interval 1 --output test1.csv

# Monitor indefinitely until Ctrl+C
sudo ./power_monitor.py --output baseline.csv

# Monitor with 0.5 second interval (high frequency sampling)
sudo ./power_monitor.py --duration 30 --interval 0.5 --output fast_sample.csv

# Quiet mode (no console output, CSV only)
sudo ./power_monitor.py --duration 60 --output quiet.csv --quiet
```

**Options:**
- `--duration, -d`: Duration in seconds (default: infinite)
- `--interval, -i`: Sampling interval in seconds (default: 1.0)
- `--output, -o`: Output CSV file path
- `--quiet, -q`: Quiet mode - suppress console output

**CSV Output Format:**
```csv
timestamp,timestamp_unix,ipmi_watts,rapl_pkg_watts,rapl_energy_uj
2025-12-05 14:30:00.123,1733408400.123,150.5,45.2,234528505562
```

**Columns:**
- `timestamp`: Human-readable timestamp
- `timestamp_unix`: Unix timestamp (seconds since epoch)
- `ipmi_watts`: IPMI instantaneous power reading (Watts)
- `rapl_pkg_watts`: RAPL package power (calculated from energy delta)
- `rapl_energy_uj`: RAPL raw energy counter (microjoules)

## System Configuration

**Server:** Dell PowerEdge R450
**CPU:** Intel Xeon Silver 4316 @ 2.30GHz
- 40 logical CPUs (20 cores, HT enabled)
- Frequency range: 800 MHz (min) - 2300 MHz (nominal/base) - 3400 MHz (turbo max)
- **Test frequencies**: 2300 MHz (nominal) vs 800 MHz (min)

**OS:** CentOS Stream 9
**Kernel:** 5.14.0-642.el9.x86_64

## Installation

### 1. Install Required Tools
```bash
sudo dnf install ipmitool stress-ng numactl kernel-tools tuned
```

### 2. Enable Tuned Service
```bash
sudo systemctl enable --now tuned
```

### 3. Switch intel_pstate to Passive Mode (CRITICAL!)
```bash
# Check current mode
cat /sys/devices/system/cpu/intel_pstate/status

# If it shows "active", switch to passive
echo passive | sudo tee /sys/devices/system/cpu/intel_pstate/status

# Verify it switched
cat /sys/devices/system/cpu/intel_pstate/status
```

**Why passive mode?** The userspace governor (required for precise frequency control) is only available in passive mode.

### 4. Load MSR Module (if not loaded)
```bash
sudo modprobe msr
```

### 5. Make Scripts Executable
```bash
chmod +x *.sh *.py
```

## Test Scenarios

All tests will run at **nominal (2300 MHz)** and **minimum (800 MHz)** CPU frequencies.

### Test 1: Idle with C6 State
- 1 core for housekeeping
- Remaining cores in C6 (deep sleep)

### Test 2: Idle with C1 State
- 1 core for housekeeping
- Remaining cores in C1 (shallow sleep)

### Test 3: Full CPU Stress
- `stress-ng` on all CPUs

### Test 4: DPDK Application
- DPDK-based app on selected cores

## Workflow

1. **Gather system info:**
   ```bash
   ./gather_system_info.sh
   ```

2. **Configure test environment:**
   - Set CPU frequency (nominal or minimum)
   - Configure C-states if needed
   - Isolate cores if needed

3. **Run power monitoring during test:**
   ```bash
   sudo ./power_monitor.py --duration 300 --interval 1 --output test1_nominal.csv
   ```

4. **Analyze results:**
   - Compare CSV files
   - Calculate average, min, max power consumption
   - Compare nominal vs minimum frequency impact

## Quick Reference: Test Configurations

### Using Tuned Profiles (Recommended)

**One-time setup:**
```bash
sudo ./setup_tuned_profiles.sh
```

### Test 1: Idle with C6 (Deep Sleep)
```bash
# Nominal frequency (2300 MHz)
sudo ./manage_test_profile.sh set powertest-1-c6-nominal
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test1_c6_nominal.csv

# Minimum frequency (800 MHz)
sudo ./manage_test_profile.sh set powertest-1-c6-min
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test1_c6_min.csv
```

### Test 2: Idle with C1 (Shallow Sleep)
```bash
# Nominal frequency
sudo ./manage_test_profile.sh set powertest-2-c1-nominal
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test2_c1_nominal.csv

# Minimum frequency
sudo ./manage_test_profile.sh set powertest-2-c1-min
./manage_test_profile.sh verify
sudo ./power_monitor.py --duration 300 --output test2_c1_min.csv
```

### Test 3: Full CPU Stress
```bash
# Nominal frequency
sudo ./manage_test_profile.sh set powertest-3-stress-nominal
./manage_test_profile.sh verify
# Terminal 1: sudo ./power_monitor.py --duration 300 --output test3_stress_nominal.csv
# Terminal 2: stress-ng --cpu 40 --timeout 300s

# Minimum frequency
sudo ./manage_test_profile.sh set powertest-3-stress-min
./manage_test_profile.sh verify
# Terminal 1: sudo ./power_monitor.py --duration 300 --output test3_stress_min.csv
# Terminal 2: stress-ng --cpu 40 --timeout 300s
```

### Test 4: DPDK Application (Requires Reboot)
```bash
# Nominal frequency
sudo ./manage_test_profile.sh set powertest-4-dpdk-nominal
sudo reboot
# After reboot:
./manage_test_profile.sh verify
# Run DPDK app on isolated cores (4-19) and power monitor

# Minimum frequency
sudo ./manage_test_profile.sh set powertest-4-dpdk-min
sudo reboot
# After reboot: run DPDK app and power monitor
```

### After Testing: Restore Defaults
```bash
sudo ./manage_test_profile.sh restore
```

---

### Using Manual Scripts (Alternative - Quick Testing)

If you prefer not to use tuned profiles:

```bash
# Example: Test 1 nominal frequency
sudo ./set_cpu_freq.sh nominal
sudo ./set_cstates.sh c6
./verify_config.sh
sudo ./power_monitor.py --duration 300 --output test1_c6_nominal.csv

# Reset when done
sudo ./reset_to_defaults.sh
```

## Notes

- Always run `power_monitor.py` with `sudo` for proper IPMI/RAPL access
- RAPL power calculation requires at least 2 samples (first sample establishes baseline)
- IPMI readings are instantaneous, RAPL is average power over the sampling interval
- For best accuracy, use consistent sampling intervals across tests
- Let the system stabilize for 10-30 seconds before starting measurements

## Troubleshooting

**IPMI not working:**
```bash
# Check IPMI device
ls -l /dev/ipmi*

# Test IPMI manually
sudo ipmitool dcmi power reading
```

**RAPL not accessible:**
```bash
# Check MSR module
lsmod | grep msr

# Load if needed
sudo modprobe msr

# Check RAPL interface
ls -l /sys/class/powercap/intel-rapl/
```

**Permission denied:**
```bash
# Run with sudo
sudo ./power_monitor.py ...
```
