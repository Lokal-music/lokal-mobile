"""Shared simulator runtime diagnostics; no application or audio substitutes."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import time
import urllib.request


def run(*args, **kwargs):
    return subprocess.run(args, timeout=kwargs.pop('timeout', 30), **kwargs)


def start(device, bundle, console):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    process = subprocess.Popen([
        'xcrun', 'simctl', 'launch', '--console', device, bundle,
        f'--vm-service-port={port}', '--disable-service-auth-codes',
        '--disable-vm-service-publication', '--enable-checked-mode',
        '--verify-entry-points',
    ], stdout=console, stderr=subprocess.STDOUT)
    # Authentication is disabled only for this ephemeral loopback debug service.
    # These launch flags are never used in a release/AOT IPA.
    return process, f'http://127.0.0.1:{port}/'


def wait_for_vm(service, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(service + 'getVM', timeout=2) as response:
                vm = json.load(response)
            if vm.get('result', {}).get('type') == 'VM':
                print('Dart VM responds on simulator loopback', flush=True)
                return True
        except (OSError, ValueError):
            pass
        time.sleep(1)
    return False


def capture(device, bundle, output, prefix, sample=False):
    try:
        run('xcrun', 'simctl', 'io', device, 'screenshot',
            str(output / f'{prefix}.png'), check=False)
    except subprocess.TimeoutExpired:
        print('Simulator screenshot timed out', flush=True)
    if not sample:
        return
    try:
        container = subprocess.check_output([
            'xcrun', 'simctl', 'get_app_container', device, bundle, 'app',
        ], text=True, timeout=15).strip()
        processes = subprocess.check_output(
            ['ps', '-axww', '-o', 'pid=', '-o', 'state=', '-o', 'command='],
            text=True, timeout=15)
        owned = [line.strip() for line in processes.splitlines() if container + '/' in line]
        (output / f'{prefix}-processes.txt').write_text('\n'.join(owned) + '\n')
        for line in owned:
            pid = line.split()[0]
            if pid.isdigit():
                run('sample', pid, '3', '-file', str(output / f'{prefix}-threads-{pid}.txt'),
                    check=False, timeout=20)
    except (OSError, subprocess.SubprocessError) as error:
        print(f'Native process sampling unavailable: {type(error).__name__}', flush=True)


def stop(device, bundle, process):
    try:
        run('xcrun', 'simctl', 'terminate', device, bundle, check=False, timeout=20)
    except subprocess.TimeoutExpired:
        print('Simulator termination timed out', flush=True)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def copy_crashes(device, output, since):
    reports = output / 'ios-crash-reports'
    reports.mkdir(exist_ok=True)
    roots = [Path.home() / 'Library/Logs/DiagnosticReports',
             Path.home() / f'Library/Developer/CoreSimulator/Devices/{device}/data/Library/Logs/CrashReporter']
    for root in roots:
        if root.exists():
            for report in root.rglob('*'):
                if report.is_file() and report.stat().st_mtime >= since and report.suffix in ('.ips', '.crash'):
                    shutil.copy2(report, reports / report.name)


def probe(app, output, prefix):
    device = os.environ['IOS_SIMULATOR_UDID']
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    started = time.time()
    run('xcrun', 'simctl', 'install', device, str(app), check=True, timeout=120)
    log = output / f'{prefix}.log'
    with log.open('w') as console:
        process, service = start(device, bundle, console)
        ready = False
        try:
            ready = wait_for_vm(service)
            # Give the application a chance to draw its initial frame.
            if ready:
                time.sleep(5)
            capture(device, bundle, output, prefix, sample=not ready)
        finally:
            stop(device, bundle, process)
            copy_crashes(device, output, started)
    print(log.read_text(errors='replace')[-20000:], flush=True)
    (output / f'{prefix}.json').write_text(json.dumps({'bundle': bundle, 'dart_vm_ready': ready}) + '\n')
    if not ready:
        raise SystemExit('Dart VM did not start; inspect native console and thread samples')
