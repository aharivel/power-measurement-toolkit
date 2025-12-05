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
        self.rapl_package = self.rapl_base / "intel-rapl:0"
        self.rapl_energy_file = self.rapl_package / "energy_uj"

        # Previous RAPL reading for delta calculation
        self.prev_rapl_energy = None
        self.prev_rapl_time = None

        # Validate interfaces
        self._check_interfaces()

    def _check_interfaces(self):
        """Check if IPMI and RAPL interfaces are available"""
        errors = []

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
        if not self.rapl_energy_file.exists():
            errors.append(f"RAPL interface not found at {self.rapl_energy_file}")

        # Check permissions
        if self.rapl_energy_file.exists():
            try:
                with open(self.rapl_energy_file, 'r') as f:
                    f.read()
            except PermissionError:
                errors.append("Permission denied reading RAPL (try running with sudo)")

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
        Read RAPL energy counter
        Returns energy in microjoules, or None on error
        """
        try:
            with open(self.rapl_energy_file, 'r') as f:
                energy_uj = int(f.read().strip())
            return energy_uj
        except Exception as e:
            if self.verbose:
                print(f"Warning: Error reading RAPL: {e}", file=sys.stderr)
            return None

    def calculate_rapl_power(self, energy_uj, timestamp):
        """
        Calculate average power from RAPL energy delta
        Returns power in Watts, or None if this is first reading
        """
        if self.prev_rapl_energy is None:
            # First reading - just store it
            self.prev_rapl_energy = energy_uj
            self.prev_rapl_time = timestamp
            return None

        # Calculate delta
        energy_delta_uj = energy_uj - self.prev_rapl_energy
        time_delta_s = timestamp - self.prev_rapl_time

        # Handle counter rollover (energy counter is typically 32-bit)
        # Max value around 4.3 billion microjoules = ~4300 joules
        if energy_delta_uj < 0:
            # Counter rolled over
            max_counter = 2**32  # Approximate, actual may vary
            energy_delta_uj += max_counter

        # Store current values for next iteration
        self.prev_rapl_energy = energy_uj
        self.prev_rapl_time = timestamp

        # Avoid division by zero
        if time_delta_s <= 0:
            return None

        # Convert to Watts: (microjoules / time_s) / 1,000,000 = Watts
        power_w = (energy_delta_uj / time_delta_s) / 1_000_000

        return power_w

    def take_measurement(self):
        """
        Take a single measurement from all interfaces
        Returns dict with timestamp and power readings
        """
        timestamp = time.time()
        timestamp_str = datetime.fromtimestamp(timestamp).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]

        # Read IPMI
        ipmi_power = self.read_ipmi_power()

        # Read RAPL
        rapl_energy = self.read_rapl_energy()
        rapl_power = None
        if rapl_energy is not None:
            rapl_power = self.calculate_rapl_power(rapl_energy, timestamp)

        measurement = {
            'timestamp': timestamp_str,
            'timestamp_unix': timestamp,
            'ipmi_watts': ipmi_power,
            'rapl_pkg_watts': rapl_power,
            'rapl_energy_uj': rapl_energy
        }

        return measurement

    def print_measurement(self, measurement):
        """Print measurement to console"""
        ipmi_str = f"{measurement['ipmi_watts']:.2f}W" if measurement['ipmi_watts'] is not None else "N/A"
        rapl_str = f"{measurement['rapl_pkg_watts']:.2f}W" if measurement['rapl_pkg_watts'] is not None else "N/A"

        print(f"[{measurement['timestamp']}] IPMI: {ipmi_str:>10} | RAPL Package: {rapl_str:>10}")

    def save_to_csv(self):
        """Save all measurements to CSV file"""
        if not self.output_file or not self.measurements:
            return

        try:
            with open(self.output_file, 'w', newline='') as f:
                fieldnames = ['timestamp', 'timestamp_unix', 'ipmi_watts',
                             'rapl_pkg_watts', 'rapl_energy_uj']
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
