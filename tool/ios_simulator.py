#!/usr/bin/env python3
"""Boot an isolated iPhone for the exact test OS and preserve boot evidence."""
import json
import os
from pathlib import Path
import re
import subprocess


def command(*args, timeout=30):
    return subprocess.check_output(args, text=True, timeout=timeout)


def main():
    version = os.environ.get('IOS_SIMULATOR_RUNTIME_VERSION') or command(
        'xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version').strip()
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version):
        raise ValueError('The simulator runtime must be an explicit OS version')
    runtime_id = 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-')
    output = Path(os.environ.get('RUNNER_TEMP', 'build/ios/runtime-evidence')) / f'ios-simulator-boot-{version}'
    output.mkdir(parents=True, exist_ok=True)
    devices_json = command('xcrun', 'simctl', 'list', 'devices', 'available', '--json')
    (output / 'devices-before.json').write_text(devices_json)
    runtimes_json = command('xcrun', 'simctl', 'list', 'runtimes', 'available', '--json')
    (output / 'runtimes.json').write_text(runtimes_json)
    devices = json.loads(devices_json)['devices']
    runtime = next((r for r in json.loads(runtimes_json)['runtimes']
                    if r['identifier'] == runtime_id and r.get('isAvailable')), None)
    requested_type = os.environ.get('IOS_SIMULATOR_DEVICE_TYPE')
    types = [] if runtime is None else [t for t in runtime.get('supportedDeviceTypes', [])
                                        if t['name'].startswith('iPhone')]
    if requested_type:
        types = [t for t in types if t['identifier'] == requested_type]
    if not types:
        raise RuntimeError(f'No compatible iPhone for required iOS {version} / {requested_type}; inspect {output}')
    device_type = sorted(types, key=lambda t: t['name'])[0]
    # Use our own device, avoiding the hosted image's preconfigured simulators.
    name = f'Lokal iPhone iOS {version}'
    candidates = [d for d in devices.get(runtime_id, [])
                  if d.get('isAvailable') and d['name'] == name
                  and d.get('deviceTypeIdentifier') == device_type['identifier']]
    if candidates:
        device = candidates[0]
    else:
        udid = command('xcrun', 'simctl', 'create', name, device_type['identifier'], runtime_id,
                       timeout=45).strip()
        device = {'udid': udid, 'name': name, 'state': 'Shutdown'}
    udid = device['udid']
    (output / 'selected.json').write_text(json.dumps({
        'udid': udid, 'name': name, 'runtime': runtime_id,
        'device_type': device_type['identifier'],
    }, indent=2) + '\n')
    # Publish before boot: later diagnostics need the UDID even if boot fails.
    if os.environ.get('GITHUB_ENV'):
        with open(os.environ['GITHUB_ENV'], 'a') as environment:
            environment.write(f'IOS_SIMULATOR_UDID={udid}\nIOS_SIMULATOR_RUNTIME={runtime_id}\n')
    try:
        with (output / 'boot.log').open('w') as log:
            if device['state'] != 'Booted':
                subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True,
                               stdout=log, stderr=subprocess.STDOUT, timeout=60)
            subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True,
                           stdout=log, stderr=subprocess.STDOUT, timeout=300)
    except (OSError, subprocess.SubprocessError) as error:
        (output / 'failure.txt').write_text(f'{type(error).__name__}: {error}\n')
        for args, destination in [
            (['xcrun', 'simctl', 'list', 'devices', '--json'], 'devices-after.json'),
            (['xcrun', 'simctl', 'io', udid, 'screenshot', str(output / 'boot.png')], 'screenshot.log'),
        ]:
            try:
                with (output / destination).open('w') as log:
                    subprocess.run(args, stdout=log, stderr=subprocess.STDOUT,
                                   check=False, timeout=20)
            except (OSError, subprocess.SubprocessError):
                pass
        raise
    print(f'iPhone simulator ready: iOS {version}, {device_type["name"]} ({udid})', flush=True)


if __name__ == '__main__':
    main()
