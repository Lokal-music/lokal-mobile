"""Coordinator contracts only; these tests do not execute an iOS simulator."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ios_simulator


RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-18-6'
DEVICE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'
RUNTIMES = json.dumps({'runtimes': [{
    'identifier': RUNTIME, 'isAvailable': True,
    'supportedDeviceTypes': [{'name': 'iPhone 16', 'identifier': DEVICE}],
}]})
DEVICES = json.dumps({'devices': {
    'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [{
        'name': 'iPhone 17', 'udid': 'unrelated', 'state': 'Booted', 'isAvailable': True,
    }],
}})


class SimulatorCoordinatorTest(unittest.TestCase):
    def test_inventory_timeout_preserves_partial_output_without_a_false_ready(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, self.environment(directory), clear=True), \
             patch.object(ios_simulator, 'command', side_effect=subprocess.TimeoutExpired(
                 ['xcrun', 'simctl', 'list'], 90,
                 output=b'CoreSimulatorService is starting\n', stderr=b'inventory pending\n')), \
             patch('builtins.print') as ready:
            with self.assertRaises(subprocess.TimeoutExpired):
                ios_simulator.main()
            evidence = Path(directory) / 'ios-simulator-boot-18.6'
            self.assertIn('TimeoutExpired', (evidence / 'discovery-failure.txt').read_text())
            self.assertIn('CoreSimulatorService', (evidence / 'discovery-stdout.log').read_text())
            self.assertIn('inventory pending', (evidence / 'discovery-stderr.log').read_text())
            self.assertFalse((evidence / 'selected.json').exists())
            self.assertFalse((Path(directory) / 'environment').exists())
            ready.assert_not_called()

    def environment(self, directory):
        return {
            'IOS_SIMULATOR_RUNTIME_VERSION': '18.6',
            'IOS_SIMULATOR_DEVICE_TYPE': DEVICE,
            'RUNNER_TEMP': directory,
            'GITHUB_ENV': str(Path(directory) / 'environment'),
            'DEVELOPER_DIR': '/Xcode/Developer',
        }

    def test_uses_exact_os_and_isolated_device_instead_of_unrelated_booted_phone(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, self.environment(directory), clear=True), \
             patch.object(ios_simulator, 'command', side_effect=[DEVICES, RUNTIMES, 'owned-udid\n']) as command, \
             patch.object(ios_simulator.subprocess, 'run') as run:
            ios_simulator.main()
            self.assertEqual(command.call_args.args, (
                'xcrun', 'simctl', 'create', 'Lokal iPhone iOS 18.6', DEVICE, RUNTIME,
            ))
            self.assertEqual(run.call_args.args[0], ['xcrun', 'simctl', 'bootstatus', 'owned-udid', '-b'])
            calls = [call.args[0] for call in run.call_args_list]
            self.assertEqual(calls[-2], ['open', '-a',
                '/Xcode/Developer/Applications/Simulator.app', '--args',
                '-CurrentDeviceUDID', 'owned-udid'])
            selected = json.loads((Path(directory) / 'ios-simulator-boot-18.6/selected.json').read_text())
            self.assertEqual(selected['runtime'], RUNTIME)
            self.assertEqual(selected['device_type'], DEVICE)

    def test_boot_timeout_preserves_identity_and_failure_instead_of_reporting_ready(self):
        def run(args, **kwargs):
            if 'bootstatus' in args:
                raise subprocess.TimeoutExpired(args, kwargs['timeout'])
            return subprocess.CompletedProcess(args, 0)

        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, self.environment(directory), clear=True), \
             patch.object(ios_simulator, 'command', side_effect=[DEVICES, RUNTIMES, 'owned-udid\n']), \
             patch.object(ios_simulator.subprocess, 'run', side_effect=run), \
             patch('builtins.print') as ready:
            with self.assertRaises(subprocess.TimeoutExpired):
                ios_simulator.main()
            self.assertIn('IOS_SIMULATOR_UDID=owned-udid', (Path(directory) / 'environment').read_text())
            evidence = Path(directory) / 'ios-simulator-boot-18.6'
            self.assertIn('TimeoutExpired', (evidence / 'failure.txt').read_text())
            self.assertTrue((evidence / 'devices-before.json').is_file())
            self.assertTrue((evidence / 'devices-after.json').is_file())
            ready.assert_not_called()

    def test_recovery_device_keeps_original_boot_evidence_and_publishes_new_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / 'ios-simulator-boot-18.6/boot.log'
            original.parent.mkdir()
            original.write_text('original boot evidence')
            environment = self.environment(directory)
            environment['IOS_SIMULATOR_SESSION_SUFFIX'] = 'control-recovery'
            with patch.dict(os.environ, environment, clear=True), \
                 patch.object(ios_simulator, 'command', side_effect=[DEVICES, RUNTIMES, 'recovery-udid\n']) as command, \
                 patch.object(ios_simulator.subprocess, 'run'):
                ios_simulator.main()
                self.assertEqual(command.call_args.args[3], 'Lokal iPhone iOS 18.6 control-recovery')
                self.assertEqual(os.environ['IOS_SIMULATOR_UDID'], 'recovery-udid')
            self.assertEqual(original.read_text(), 'original boot evidence')
            self.assertTrue((Path(directory) / 'ios-simulator-boot-18.6-control-recovery/selected.json').exists())

    def test_missing_required_runtime_never_falls_back_to_another_os(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(os.environ, self.environment(directory), clear=True), \
             patch.object(ios_simulator, 'command', side_effect=[DEVICES, '{"runtimes":[]}']), \
             patch.object(ios_simulator.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'required iOS 18.6'):
                ios_simulator.main()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
