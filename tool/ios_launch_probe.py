#!/usr/bin/env python3
"""Capture native startup output and crash reports before waiting for Dart VM."""
import os
from pathlib import Path
import shutil
import subprocess
import time

device = os.environ['IOS_SIMULATOR_UDID']
output = Path(os.environ['RUNNER_TEMP'])
reports = output / 'ios-crash-reports'
reports.mkdir(exist_ok=True)
started = time.time()
subprocess.run(['xcrun', 'simctl', 'install', device,
                'build/ios/iphonesimulator/Runner.app'], check=True)
with (output / 'ios-launch.log').open('w') as console:
    launch = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console',
                               device, 'app.lokal.mobile'],
                              stdout=console, stderr=subprocess.STDOUT)
    try:
        launch.wait(timeout=15)
        exited = True
    except subprocess.TimeoutExpired:
        exited = False
    processes = subprocess.check_output(
        ['xcrun', 'simctl', 'spawn', device, 'launchctl', 'list'], text=True)
    services = [line.split() for line in processes.splitlines()
                if 'UIKitApplication:app.lokal.mobile[' in line]
    alive = any(parts and parts[0].isdigit() for parts in services)
    subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot',
                    str(output / 'lokal-iphone.png')], check=True)
    if not exited:
        subprocess.run(['xcrun', 'simctl', 'terminate', device,
                        'app.lokal.mobile'], check=False)
        try:
            launch.wait(timeout=10)
        except subprocess.TimeoutExpired:
            launch.terminate()
            launch.wait(timeout=10)

# CrashReporter can finish writing just after simctl observes termination.
time.sleep(3)
roots = [Path.home() / 'Library/Logs/DiagnosticReports',
         Path.home() / f'Library/Developer/CoreSimulator/Devices/{device}/data/Library/Logs/CrashReporter']
for root in roots:
    if root.exists():
        for report in root.rglob('*'):
            if report.is_file() and report.stat().st_mtime >= started and report.suffix in ('.ips', '.crash'):
                shutil.copy2(report, reports / report.name)
print((output / 'ios-launch.log').read_text(errors='replace')[-20000:])
if exited or not alive:
    raise SystemExit('Native app exited during the first 15 seconds; inspect launch log and crash reports')
print('Native app remained running through the first-launch probe')
