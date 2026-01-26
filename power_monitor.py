#!/usr/bin/env python3
"""
Power Measurement Tool for CPU Frequency Impact Study
Reads power consumption from IPMI and RAPL interfaces

Usage:
    sudo ./power_monitor.py --duration 60 --interval 1 --output test1.csv
"""

import argparse
import csv
import subprocess
import time
import sys
import os
import signal
from datetime import datetime
from pathlib import Path


class PowerMonitor:
    """Monitor power consumption via IPMI and RAPL"""

    def __init__(self, interval=1.0, output_file=None, verbose=True):
        self.interval = interval
        self.output_file = output_file
        self.verbose = verbose
        self.running = False
        self.measurements = []

        # RAPL paths
        self.rapl_base = Path("/sys/class/powercap/intel-rapl")

        # Discover RAPL domains dynamically
        self.rapl_domains = self._discover_rapl_domains()

        # Previous RAPL readings for delta calculation (keyed by domain name)
        self.prev_rapl_energy = {}
        self.prev_rapl_time = None

        # Validate interfaces
        self._check_interfaces()

    def _discover_rapl_domains(self):
        """
        Discover available RAPL domains dynamically.
        Returns dict of {domain_name: energy_file_path}

        Typical domains:
        - intel-rapl:0 (package-0)
        - intel-rapl:0:0 (core on package-0)
        - intel-rapl:1 (package-1)
        - intel-rapl:1:0 (core on package-1)
        """
        domains = {}

        if not self.rapl_base.exists():
            return domains

        # Find all package domains (intel-rapl:X)
        for pkg_dir in sorted(self.rapl_base.glob("intel-rapl:*")):
            if pkg_dir.is_dir():
                energy_file = pkg_dir / "energy_uj"
                name_file = pkg_dir / "name"

                if energy_file.exists():
                    # Get domain name (e.g., "package-0")
                    domain_name = pkg_dir.name
                    if name_file.exists():
                        friendly_name = name_file.read_text().strip()
                        domain_name = f"{friendly_name}"

                    domains[domain_name] = energy_file

                    # Look for subdomains (intel-rapl:X:Y)
                    for sub_dir in sorted(pkg_dir.glob("intel-rapl:*:*")):
                        if sub_dir.is_dir():
                            sub_energy_file = sub_dir / "energy_uj"
                            sub_name_file = sub_dir / "name"

                            if sub_energy_file.exists():
                                # Get subdomain name (e.g., "core")
                                sub_domain_name = sub_dir.name
                                if sub_name_file.exists():
                                    friendly_name = sub_name_file.read_text().strip()
                                    # Include parent package in name
                                    sub_domain_name = f"{domain_name}-{friendly_name}"

                                domains[sub_domain_name] = sub_energy_file

        return domains

    def _check_interfaces(self):
        """Check if IPMI and RAPL interfaces are available"""
        errors = []
        warnings = []

        # Check ipmitool
        try:
            result = subprocess.run(
                ["which", "ipmitool"],
                capture_output=True,
                check=False
            )
            if result.returncode != 0:
                errors.append("ipmitool not found in PATH")
        except Exception as e:
            errors.append(f"Error checking ipmitool: {e}")

        # Check RAPL
        if not self.rapl_domains:
            errors.append(f"No RAPL domains found at {self.rapl_base}")
        else:
            # Check permissions on first domain
            first_domain = list(self.rapl_domains.values())[0]
            try:
                with open(first_domain, 'r') as f:
                    f.read()
            except PermissionError:
                errors.append("Permission denied reading RAPL (try running with sudo)")

            # Print discovered domains
            if self.verbose:
                print(f"Discovered {len(self.rapl_domains)} RAPL domains:")
                for name, path in self.rapl_domains.items():
                    print(f"  - {name}")

        if errors:
            print("ERROR: Interface validation failed:", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
            sys.exit(1)

    def read_ipmi_power(self):
        """
        Read instantaneous power consumption via IPMI
        Returns power in Watts, or None on error
        """
        try:
            result = subprocess.run(
                ["ipmitool", "dcmi", "power", "reading"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False
            )

            if result.returncode != 0:
                if self.verbose:
                    print(f"Warning: ipmitool failed: {result.stderr.strip()}",
                          file=sys.stderr)
                return None

            # Parse output - looking for "Instantaneous power reading: XXX Watts"
            for line in result.stdout.split('\n'):
                if "Instantaneous power reading" in line:
                    # Extract number before "Watts"
                    parts = line.split(':')
                    if len(parts) >= 2:
                        power_str = parts[1].strip().split()[0]
                        return float(power_str)

            if self.verbose:
                print("Warning: Could not parse IPMI output", file=sys.stderr)
            return None

        except subprocess.TimeoutExpired:
            if self.verbose:
                print("Warning: ipmitool timeout", file=sys.stderr)
            return None
        except Exception as e:
            if self.verbose:
                print(f"Warning: Error reading IPMI: {e}", file=sys.stderr)
            return None

    def read_rapl_energy(self):
        """
        Read RAPL energy counters for all domains
        Returns dict of {domain_name: energy_uj}, or empty dict on error
        """
        energies = {}
        for domain_name, energy_file in self.rapl_domains.items():
            try:
                with open(energy_file, 'r') as f:
                    energy_uj = int(f.read().strip())
                energies[domain_name] = energy_uj
            except Exception as e:
                if self.verbose:
                    print(f"Warning: Error reading RAPL {domain_name}: {e}", file=sys.stderr)
        return energies

    def calculate_rapl_power(self, energies, timestamp):
        """
        Calculate average power from RAPL energy delta for all domains
        Returns dict of {domain_name: power_watts}, None values for first reading
        """
        powers = {}

        if self.prev_rapl_time is None:
            # First reading - just store values
            self.prev_rapl_energy = energies.copy()
            self.prev_rapl_time = timestamp
            return {name: None for name in energies}

        time_delta_s = timestamp - self.prev_rapl_time

        # Avoid division by zero
        if time_delta_s <= 0:
            return {name: None for name in energies}

        for domain_name, energy_uj in energies.items():
            prev_energy = self.prev_rapl_energy.get(domain_name)

            if prev_energy is None:
                powers[domain_name] = None
                continue

            # Calculate delta
            energy_delta_uj = energy_uj - prev_energy

            # Handle counter rollover (energy counter is typically 32-bit)
            if energy_delta_uj < 0:
                max_counter = 2**32
                energy_delta_uj += max_counter

            # Convert to Watts: (microjoules / time_s) / 1,000,000 = Watts
            power_w = (energy_delta_uj / time_delta_s) / 1_000_000
            powers[domain_name] = power_w

        # Store current values for next iteration
        self.prev_rapl_energy = energies.copy()
        self.prev_rapl_time = timestamp

        return powers

    def take_measurement(self):
        """
        Take a single measurement from all interfaces
        Returns dict with timestamp and power readings
        """
        timestamp = time.time()
        timestamp_str = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]

        # Read IPMI
        ipmi_power = self.read_ipmi_power()

        # Read RAPL (all domains)
        rapl_energies = self.read_rapl_energy()
        rapl_powers = self.calculate_rapl_power(rapl_energies, timestamp)

        measurement = {
            'timestamp': timestamp_str,
            'timestamp_unix': timestamp,
            'ipmi_watts': ipmi_power,
        }

        # Add each RAPL domain's power to measurement
        for domain_name, power in rapl_powers.items():
            # Sanitize domain name for CSV column (replace - with _)
            col_name = f"rapl_{domain_name.replace('-', '_')}_watts"
            measurement[col_name] = power

        return measurement

    def print_measurement(self, measurement):
        """Print measurement to console"""
        ipmi_str = f"{measurement['ipmi_watts']:.2f}W" if measurement['ipmi_watts'] is not None else "N/A"

        # Build RAPL string from all domains
        rapl_parts = []
        for key, value in measurement.items():
            if key.startswith('rapl_') and key.endswith('_watts'):
                # Extract domain name from key
                domain = key.replace('rapl_', '').replace('_watts', '').replace('_', '-')
                if value is not None:
                    rapl_parts.append(f"{domain}:{value:.1f}W")
                else:
                    rapl_parts.append(f"{domain}:N/A")

        rapl_str = " | ".join(rapl_parts) if rapl_parts else "N/A"

        print(f"[{measurement['timestamp']}] IPMI: {ipmi_str:>8} | RAPL: {rapl_str}")

    def save_to_csv(self):
        """Save all measurements to CSV file"""
        if not self.output_file or not self.measurements:
            return

        try:
            # Get all field names from the first measurement
            # (they should all have the same fields)
            if self.measurements:
                fieldnames = list(self.measurements[0].keys())
            else:
                fieldnames = ['timestamp', 'timestamp_unix', 'ipmi_watts']

            with open(self.output_file, 'w', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(self.measurements)

            if self.verbose:
                print(f"\nSaved {len(self.measurements)} measurements to {self.output_file}")
        except Exception as e:
            print(f"Error saving to CSV: {e}", file=sys.stderr)

    def run(self, duration=None):
        """
        Run the monitoring loop

        Args:
            duration: Duration in seconds, or None for infinite
        """
        self.running = True
        start_time = time.time()
        measurement_count = 0

        print("=" * 80)
        print("Power Monitoring Started")
        print(f"Interval: {self.interval}s")
        if duration:
            print(f"Duration: {duration}s")
        else:
            print("Duration: Infinite (Ctrl+C to stop)")
        if self.output_file:
            print(f"Output: {self.output_file}")
        print("=" * 80)
        print()

        # Take initial RAPL reading (for delta calculation)
        initial = self.take_measurement()
        if self.verbose:
            print("Initial RAPL reading taken (no power calculated yet)")

        try:
            while self.running:
                # Check duration
                if duration and (time.time() - start_time) >= duration:
                    break

                # Take measurement
                measurement = self.take_measurement()
                self.measurements.append(measurement)
                measurement_count += 1

                # Print to console
                if self.verbose:
                    self.print_measurement(measurement)

                # Sleep until next interval
                time.sleep(self.interval)

        except KeyboardInterrupt:
            print("\n\nMonitoring stopped by user (Ctrl+C)")

        finally:
            self.running = False
            print("\n" + "=" * 80)
            print(f"Monitoring Complete - {measurement_count} measurements taken")
            print("=" * 80)

            # Save to CSV
            if self.output_file:
                self.save_to_csv()


def main():
    parser = argparse.ArgumentParser(
        description='Monitor power consumption via IPMI and RAPL',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Monitor for 60 seconds, 1 second interval, save to CSV
  sudo ./power_monitor.py --duration 60 --interval 1 --output test1.csv

  # Monitor indefinitely until Ctrl+C
  sudo ./power_monitor.py --output baseline.csv

  # Monitor with 0.5 second interval
  sudo ./power_monitor.py --duration 30 --interval 0.5 --output fast_sample.csv

  # Quiet mode (no console output, only CSV)
  sudo ./power_monitor.py --duration 60 --output quiet.csv --quiet
        """
    )

    parser.add_argument(
        '--duration', '-d',
        type=float,
        default=None,
        help='Duration to monitor in seconds (default: infinite)'
    )

    parser.add_argument(
        '--interval', '-i',
        type=float,
        default=1.0,
        help='Sampling interval in seconds (default: 1.0)'
    )

    parser.add_argument(
        '--output', '-o',
        type=str,
        default=None,
        help='Output CSV file path (optional)'
    )

    parser.add_argument(
        '--quiet', '-q',
        action='store_true',
        help='Quiet mode - no console output'
    )

    args = parser.parse_args()

    # Check if running as root
    if os.geteuid() != 0:
        print("Warning: Not running as root. IPMI and RAPL access may fail.",
              file=sys.stderr)
        print("Consider running with: sudo", file=sys.stderr)
        print()

    # Create monitor
    monitor = PowerMonitor(
        interval=args.interval,
        output_file=args.output,
        verbose=not args.quiet
    )

    # Run monitoring
    monitor.run(duration=args.duration)

    return 0


if __name__ == '__main__':
    sys.exit(main())
