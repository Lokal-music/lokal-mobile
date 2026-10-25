#!/usr/bin/env python3
"""Boot an available iPhone simulator and record its UDID for Actions."""
import json
import os
import subprocess

result = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True)
devices = json.loads(result)['devices']
version = os.environ.get('IOS_SIMULATOR_RUNTIME_VERSION') or subprocess.check_output(
    ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
runtime_id = 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-')
# iOS 18.4/18.5 simulator runtimes have a known missing libswiftWebKit dylib
# (WebKit bug 293831). Select the declared test OS, not whichever alphabetically
# named iPhone happens to belong to the first installed runtime.
candidates = [d for runtime, entries in devices.items() if runtime == runtime_id
              for d in entries if d.get('isAvailable') and d['name'].startswith('iPhone')]
if not candidates:
    raise SystemExit(f'No available iPhone for required iOS {version}; installed runtimes: {list(devices)}')
device = sorted(candidates, key=lambda d: (d['state'] != 'Booted', d['name']))[0]
if device['state'] != 'Booted':
    subprocess.run(['xcrun', 'simctl', 'boot', device['udid']], check=True)
subprocess.run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], check=True, timeout=300)
if os.environ.get('GITHUB_ENV'):
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        output.write(f"IOS_SIMULATOR_UDID={device['udid']}\n")
        output.write(f"IOS_SIMULATOR_RUNTIME={runtime_id}\n")
print(f"iPhone simulator ready: iOS {version}, {device['name']} ({device['udid']})")
