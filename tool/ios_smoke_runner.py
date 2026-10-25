#!/usr/bin/env python3
"""Run real integration tests through a directly checked simulator VM service.

Flutter's normal simulator attachment discovers a URI through unified logs.
Use the supported flutter-drive existing-app interface instead, preserving app
console output and failing promptly when the VM itself does not start.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

device = os.environ['IOS_SIMULATOR_UDID']
output = Path(os.environ['RUNNER_TEMP'])
bundle = 'app.lokal.mobile'
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
service = f'http://127.0.0.1:{port}/'
subprocess.run(['xcrun', 'simctl', 'install', device,
                'build/ios/iphonesimulator/Runner.app'], check=True)
with (output / 'ios-smoke-console.log').open('w') as console:
    # The simulator shares the host's loopback interface. Disable debug-service
    # auth only on this ephemeral, locally bound test instance, never in an IPA.
    launch = subprocess.Popen([
        'xcrun', 'simctl', 'launch', '--console', device, bundle,
        f'--vm-service-port={port}', '--disable-service-auth-codes',
        '--disable-vm-service-publication', '--enable-checked-mode',
        '--verify-entry-points',
    ], stdout=console, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 90
        while True:
            try:
                with urllib.request.urlopen(service + 'getVM', timeout=2) as response:
                    vm = json.load(response)
                if vm.get('result', {}).get('type') == 'VM':
                    print('Simulator Dart VM service responds on loopback', flush=True)
                    break
            except (OSError, ValueError):
                pass
            if launch.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Simulator Dart VM did not start; inspect native console/crash reports')
            time.sleep(1)
        subprocess.run([
            'flutter', 'drive', '--no-pub', '--no-dds', '-d', device,
            '--target=integration_test/ios_smoke_test.dart',
            '--driver=integration_test/ios_driver.dart',
            f'--use-existing-app={service}', '--verbose',
        ], check=True, timeout=300)
    finally:
        subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot',
                        str(output / 'ios-smoke-iphone.png')], check=False)
        subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], check=False)
        try:
            launch.wait(timeout=10)
        except subprocess.TimeoutExpired:
            launch.terminate()
            launch.wait(timeout=10)
