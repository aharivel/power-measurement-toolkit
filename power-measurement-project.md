# Power Measurement Project - PowerEdge R450

## Objective
Verify the impact of CPU frequency on power consumption of a PowerEdge R450 server running CentOS Stream 9.

## Phase 1: Preparation

### 1.1 CPU Information Gathering
- Retrieve and document CPU specifications
- Document current CPU configuration

### 1.2 Measurement Tool Development
Create a script/program (Python/Golang/Bash) to measure power consumption by reading:
- **IPMI**: System-level power consumption
- **RAPL** (Running Average Power Limit): CPU-level power consumption

## Phase 2: Test Scenarios

All tests will be executed at **TWO CPU frequencies**:
- Nominal (maximum) CPU frequency
- Minimum CPU frequency

### Test 1: Idle with C6 State
- 1 core for housekeeping (OS + measurement tool)
- All remaining cores in C6 state (deep sleep)

### Test 2: Idle with C1 State
- 1 core for housekeeping (OS + measurement tool)
- All remaining cores in C1 state (shallow sleep)

### Test 3: Full CPU Stress
- stress-ng running on all CPUs

### Test 4: DPDK Application
- DPDK-based application running on selected cores
- Details to be provided later

## Phase 3: Configuration Requirements

### Tasks to Investigate/Implement:
- [ ] How to isolate CPU cores
- [ ] How to fix CPU frequency to nominal frequency
- [ ] How to fix CPU frequency to minimum frequency
- [ ] How to set CPU C-states (C1 vs C6)
- [ ] How to verify CPU state configuration

## Test Matrix

| Test Scenario | CPU Frequency | Cores Configuration | Expected Measurements |
|---------------|---------------|---------------------|----------------------|
| Test 1 (C6)   | Nominal       | 1 housekeeping + rest C6 | IPMI + RAPL |
| Test 1 (C6)   | Minimum       | 1 housekeeping + rest C6 | IPMI + RAPL |
| Test 2 (C1)   | Nominal       | 1 housekeeping + rest C1 | IPMI + RAPL |
| Test 2 (C1)   | Minimum       | 1 housekeeping + rest C1 | IPMI + RAPL |
| Test 3 (stress-ng) | Nominal  | All cores stressed | IPMI + RAPL |
| Test 3 (stress-ng) | Minimum  | All cores stressed | IPMI + RAPL |
| Test 4 (DPDK) | Nominal       | Selected cores + DPDK | IPMI + RAPL |
| Test 4 (DPDK) | Minimum       | Selected cores + DPDK | IPMI + RAPL |

**Total: 8 test runs**

## System Configuration (from DUT)

### Hardware
- **Server**: Dell PowerEdge R450 (Serial: 942XP04)
- **CPU**: Intel Xeon Silver 4316 @ 2.30GHz
  - 1 socket, 20 cores/socket, 2 threads/core = **40 logical CPUs**
  - **Min Frequency**: 800 MHz (800000 kHz)
  - **Nominal/Base Frequency**: 2300 MHz (2300000 kHz) - guaranteed frequency
  - **Max Turbo Frequency**: 3400 MHz (3400000 kHz) - boost frequency

  - **NUMA**: Single node (all CPUs on node 0)

**Important**: Tests will compare **Nominal (2300 MHz)** vs **Minimum (800 MHz)**
- NOT using max turbo (3400 MHz) for tests

### Current Configuration
- **Frequency Governor**: performance (currently running)
- **Intel P-state**: Active (passive mode, turbo enabled)
- **C-States Available**:
  - C0 (POLL): enabled
  - C1: enabled
  - C1E: enabled
  - **C6: DISABLED** (needs to be enabled for Test 1)

### Power Measurement Interfaces
- **RAPL**: ✓ Available (MSR module loaded, powercap interface working)
  - Domain: intel-rapl:0 (package-0)
- **IPMI**: ✗ ipmitool NOT installed (needs installation)
- **turbostat**: ✓ Available (for monitoring/validation)

### Tools Status
- ✓ Installed: turbostat, cpupower, dmidecode, lscpu
- ✗ Missing: **ipmitool**, **stress-ng**, numactl

### Configuration Approach

**Two methods available:**
1. **Tuned Profiles** (Recommended) - Production-grade, persistent
   - 8 profiles created for all test scenarios
   - Based on Red Hat/CentOS best practices
   - Requires reboot only for Test 4 (CPU isolation)

2. **Manual Scripts** (Alternative) - Quick iteration
   - Simple scripts for frequency, C-states, isolation
   - No reboot needed (except for kernel parameters)
   - Good for rapid testing

### Setup Completed
- ✓ Power monitoring tool (`power_monitor.py`)
- ✓ System information gatherer (`gather_system_info.sh`)
- ✓ Tuned profiles for all 8 test configurations
- ✓ Profile management script (`manage_test_profile.sh`)
- ✓ Manual configuration scripts (alternative approach)
- ✓ Verification tools
- ✓ Complete documentation

### Action Items Before Testing
1. ~~Install missing tools~~ ✓ DONE: `sudo dnf install ipmitool stress-ng numactl`
2. Install tuned profiles: `sudo ./setup_tuned_profiles.sh`
3. Verify IPMI/BMC access with ipmitool
4. Test profile switching with `./manage_test_profile.sh`
5. Run verification: `./manage_test_profile.sh verify`

## Notes
- Server: PowerEdge R450
- OS: CentOS Stream 9
- Measurement sources: IPMI (system power) + RAPL (CPU power)
