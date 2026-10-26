#!/usr/bin/env python3
"""Allow one isolated simulator recovery before any Lokal runtime test starts.

Only the generated Flutter control app may use this coordinator. Both attempts'
evidence survives, and a second VM-readiness failure fails the job normally.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

import ios_simulator
from ios_runtime import probe


def verify(app: Path, output: Path):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.lokal.lokalControl':
        raise ValueError('Simulator recovery is restricted to the minimal control app')
    try:
        probe(app, output, 'ios-control')
        return
    except SystemExit:
        # probe exits only when its VM readiness check fails. Installation,
        # build and other command failures propagate without being retried.
        print('Minimal control VM failed; preserving evidence and trying one fresh simulator', flush=True)

    previous = os.environ['IOS_SIMULATOR_UDID']
    with (output / 'ios-control-recovery-shutdown.log').open('w') as log:
        try:
            subprocess.run(['xcrun', 'simctl', 'shutdown', previous],
                           stdout=log, stderr=subprocess.STDOUT, check=False, timeout=30)
        except subprocess.TimeoutExpired as error:
            log.write(str(error) + '\n')
    os.environ['IOS_SIMULATOR_SESSION_SUFFIX'] = 'control-recovery'
    ios_simulator.main()
    # Bring up Simulator.app for the new owned device, including its foreground
    # launch services, instead of relying solely on a headless boot.
    simulator = Path(os.environ['DEVELOPER_DIR']) / 'Applications/Simulator.app'
    subprocess.run(['open', '-a', str(simulator), '--args',
                    '-CurrentDeviceUDID', os.environ['IOS_SIMULATOR_UDID']],
                   check=True, timeout=20)
    probe(app, output, 'ios-control-recovery')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    verify(args.app, Path(os.environ['RUNNER_TEMP']))
