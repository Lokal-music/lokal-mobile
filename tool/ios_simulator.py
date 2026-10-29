#!/usr/bin/env python3
"""Boot an isolated iPhone for the exact test OS and preserve boot evidence."""
import json
import argparse
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
    suffix = os.environ.get('IOS_SIMULATOR_SESSION_SUFFIX', '')
    if suffix and not re.fullmatch(r'[a-zA-Z0-9-]{1,40}', suffix):
        raise ValueError('Invalid simulator session suffix')
    evidence_name = f'ios-simulator-boot-{version}' + (f'-{suffix}' if suffix else '')
    output = Path(os.environ.get('RUNNER_TEMP', 'build/ios/runtime-evidence')) / evidence_name
    output.mkdir(parents=True, exist_ok=True)
    try:
        # CoreSimulatorService is cold on an isolated hosted Mac. Inventory
        # needs its own bounded startup allowance, before a UDID exists.
        devices_json = command('xcrun', 'simctl', 'list', 'devices', 'available', '--json', timeout=90)
        (output / 'devices-before.json').write_text(devices_json)
        runtimes_json = command('xcrun', 'simctl', 'list', 'runtimes', 'available', '--json', timeout=90)
        (output / 'runtimes.json').write_text(runtimes_json)
    except (OSError, subprocess.SubprocessError) as error:
        (output / 'discovery-failure.txt').write_text(f'{type(error).__name__}: {error}\n')
        for attribute in ('stdout', 'stderr'):
            partial = getattr(error, attribute, None)
            if partial:
                if isinstance(partial, bytes):
                    partial = partial.decode('utf-8', errors='replace')
                (output / f'discovery-{attribute}.log').write_text(partial)
        raise
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
    name = f'Lokal iPhone iOS {version}' + (f' {suffix}' if suffix else '')
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
    os.environ['IOS_SIMULATOR_UDID'] = udid
    os.environ['IOS_SIMULATOR_RUNTIME'] = runtime_id
    os.environ['IOS_SIMULATOR_CREATED_THIS_ATTEMPT'] = '0' if candidates else '1'
    (output / 'selected.json').write_text(json.dumps({
        'udid': udid, 'name': name, 'runtime': runtime_id,
        'device_type': device_type['identifier'],
        'created_this_attempt': not candidates,
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
            # A device reported as Booted can still lack a usable display on a
            # fresh hosted Mac. Start its GUI session before waiting for full
            # SpringBoard readiness; bootstatus and the control app remain gates.
            developer = os.environ.get('DEVELOPER_DIR') or command('xcode-select', '-p').strip()
            simulator = Path(developer) / 'Applications/Simulator.app'
            subprocess.run(['open', '-a', str(simulator), '--args',
                            '-CurrentDeviceUDID', udid], check=True,
                           stdout=log, stderr=subprocess.STDOUT, timeout=20)
            subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True,
                           stdout=log, stderr=subprocess.STDOUT, timeout=300)
    except (OSError, subprocess.SubprocessError) as error:
        (output / 'failure.txt').write_text(f'{type(error).__name__}: {error}\n')
        for args, destination in [
            (['xcrun', 'simctl', 'list', 'devices', '--json'], 'devices-after.json'),
            (['xcrun', 'simctl', 'io', udid, 'screenshot', str(output / 'boot.png')], 'screenshot.log'),
            (['xcrun', 'simctl', 'spawn', udid, 'log', 'show', '--last', '5m',
              '--style', 'compact', '--predicate',
              'process == "SpringBoard" OR process == "backboardd"'], 'system-display.log'),
        ]:
            try:
                with (output / destination).open('w') as log:
                    subprocess.run(args, stdout=log, stderr=subprocess.STDOUT,
                                   check=False, timeout=20)
            except (OSError, subprocess.SubprocessError):
                pass
        raise
    print(f'iPhone simulator ready: iOS {version}, {device_type["name"]} ({udid})', flush=True)


def boot_before_install():
    """One fresh-device recovery only for bootstatus on a newly created phone.

    Call strictly before app installation. Existing-device, inventory, install,
    control-VM and application failures never qualify for this path.
    """
    try:
        main()
        return
    except subprocess.TimeoutExpired as error:
        previous = os.environ.get('IOS_SIMULATOR_UDID')
        if (not previous or os.environ.get('IOS_SIMULATOR_CREATED_THIS_ATTEMPT') != '1'
                or list(error.cmd) != ['xcrun', 'simctl', 'bootstatus', previous, '-b']):
            raise
        # Keep the original evidence directory untouched. No erase/delete,
        # service kill or shutdown-all can affect another simulator or app.
        output = Path(os.environ.get('RUNNER_TEMP', 'build/ios/runtime-evidence'))
        with (output / 'ios-preinstall-boot-recovery.log').open('w') as log:
            log.write(f'First newly-created device bootstatus timed out: {previous}\n')
            log.flush()
            try:
                subprocess.run(['xcrun', 'simctl', 'shutdown', previous],
                               stdout=log, stderr=subprocess.STDOUT, check=False, timeout=30)
            except (OSError, subprocess.SubprocessError) as shutdown_error:
                log.write(f'{type(shutdown_error).__name__}: {shutdown_error}\n')
        os.environ['IOS_SIMULATOR_SESSION_SUFFIX'] = 'boot-recovery-' + previous[:8]
        print('New test device failed to boot before installation; preserving evidence '
              'and trying one fresh device of the same required OS', flush=True)
    # Deliberately outside the catch: any second failure propagates normally.
    main()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recover-preinstall-boot', action='store_true')
    args = parser.parse_args()
    if args.recover_preinstall_boot:
        boot_before_install()
    else:
        main()
