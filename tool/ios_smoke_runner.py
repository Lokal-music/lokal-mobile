#!/usr/bin/env python3
"""Execute real integration tests through Flutter's existing-app driver."""
import os
from pathlib import Path
import subprocess
import time
from ios_runtime import capture, copy_crashes, run, start, stop, wait_for_vm
from ios_desktop_fixture import desktop_fixture

device = os.environ['IOS_SIMULATOR_UDID']
output = Path(os.environ.get('LOKAL_IOS_RUNTIME_EVIDENCE_DIR', os.environ['RUNNER_TEMP']))
output.mkdir(parents=True, exist_ok=True)
bundle = 'app.lokal.mobile'
started = time.time()
run('xcrun', 'simctl', 'install', device,
    'build/ios/iphonesimulator/Runner.app', check=True, timeout=120)
with desktop_fixture(output), (output / 'ios-smoke-console.log').open('w') as console:
    launch, service = start(device, bundle, console)
    passed = False
    try:
        if not wait_for_vm(service):
            raise RuntimeError('Simulator Dart VM did not start')
        subprocess.run([
            'flutter', 'drive', '--no-pub', '--no-dds', '-d', device,
            '--target=integration_test/ios_smoke_test.dart',
            '--driver=integration_test/ios_driver.dart',
            f'--use-existing-app={service}', '--verbose',
        ], check=True, timeout=300)
        passed = True
    finally:
        capture(device, bundle, output, 'ios-smoke-iphone', sample=not passed)
        stop(device, bundle, launch)
        copy_crashes(device, output, started)
