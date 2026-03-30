# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

CPU power measurement tool suite for analyzing the impact of CPU frequency and C-states on power consumption. Measures power via two interfaces:
- **IPMI**: System-level power (Watts) via `ipmitool dcmi power reading`
- **RAPL**: CPU package power per socket via `/sys/devices/virtual/powercap/intel-rapl/intel-rapl:{N}/energy_uj`

Each hardware variant gets its own branch. Current branches:
- `main` / `xr8620t-xeon-gold-6433n`: Dell PowerEdge XR8620t, Intel Xeon Gold 6433N, 64 cores, CentOS Stream 9
- `xeon-6780e`: HPE ProLiant Compute DL380 Gen12, Intel Xeon 6780E @ 2.2 GHz, 288 physical cores (no HT), 2 sockets, CentOS Stream 10. NUMA0: CPUs 0-71,144-215 — NUMA1: CPUs 72-143,216-287.

## Hardware: Intel Xeon 6780E

- 2 sockets × 144 physical cores = 288 total (no hyperthreading)
- Base frequency: 2200 MHz
- C-states: POLL (0 µs), C1 (1 µs), C1E (2 µs), C6S (270 µs, module-scoped), C6SP (310 µs, package-scoped)
  - C6S: all 4 cores in a module must request C6S before the module + L2 powers down
  - C6SP: all modules in a socket must be in C6S before the socket enters deepest sleep
  - Housekeeping cores (CPU 0, CPU 72) prevent their package from reaching C6SP in practice
- intel_pstate in **passive** mode (appears as intel_cpufreq driver)
- CPU isolation: housekeeping on CPU 0 (NUMA0) and CPU 72 (NUMA1); isolated: 1-71,73-143,144-287

## Running the Tools

All scripts require `sudo`. No build step needed.

**Set CPU configuration** (freq + C-states in one step):
```bash
sudo ./set_config.sh 2200 c6   # nominal freq + deep sleep
sudo ./set_config.sh 800  c6   # min freq + deep sleep
sudo ./set_config.sh 2200 c1   # nominal freq + shallow sleep
sudo ./set_config.sh 800  c1   # min freq + shallow sleep
```

**Start power monitoring** (outputs CSV):
```bash
sudo python3 power_monitor.py --output result/test_name.csv --duration 60
```

**Verify configuration**:
```bash
./verify_config.sh
./verify_config.sh --detailed
```

**Gather system info**:
```bash
sudo ./gather_system_info.sh
```

**Reset to defaults**:
```bash
sudo ./reset_to_defaults.sh
```

**Kernel CPU isolation** (persistent across reboots, requires grubby):
```bash
sudo ./setup_kernel_isolation.sh apply   # adds isolcpus/nohz_full/rcu_nocbs
sudo ./setup_kernel_isolation.sh remove  # removes them
sudo ./setup_kernel_isolation.sh status  # shows current state
```

## Test Matrix

4 base configurations × optional stress load:

| Test | Command | Workload |
|------|---------|----------|
| 1a   | `set_config.sh 2200 c6` | Idle (deep sleep) |
| 1b   | `set_config.sh 800 c6`  | Idle (deep sleep) |
| 2a   | `set_config.sh 2200 c1` | Idle (shallow sleep) |
| 2b   | `set_config.sh 800 c1`  | Idle (shallow sleep) |

For stress tests, run `stress-ng --cpu 0 --timeout 60s` on top of any configuration.

## CSV Output Format

`power_monitor.py` produces:
```
timestamp,timestamp_unix,ipmi_watts,rapl_pkg0_watts,rapl_pkg0_energy_uj,rapl_pkg1_watts,rapl_pkg1_energy_uj
2025-12-05 14:30:00.123,1733408400.123,289.0,68.45,234528505562,71.18,198372641023
```

Results are stored in `result/` (gitignored).

## Architecture Notes

- No build system — pure shell + Python
- intel_pstate must be in **passive** mode for userspace governor to be available
- RAPL read via `/sys/devices/virtual/powercap/` (not `/sys/class/powercap/` — pathlib.glob does not follow symlinks in sysfs)
- C-state names on this CPU: POLL, C1, C1E, C6S, C6SP (not generic "C6")
- `setup_kernel_isolation.sh` uses `grubby --update-kernel=ALL` for persistent kernel cmdline changes
