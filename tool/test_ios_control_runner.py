"""Coordinator contracts; these checks do not execute an Apple simulator."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ios_control_runner


class ControlRecoveryTest(unittest.TestCase):
    def app(self, directory, bundle='app.lokal.lokalControl'):
        app = Path(directory) / 'Runner.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle}))
        return app

    def test_ready_control_does_not_restart_simulator(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(ios_control_runner, 'probe') as probe, \
             patch.object(ios_control_runner.ios_simulator, 'main') as boot:
            ios_control_runner.verify(self.app(directory), Path(directory))
            probe.assert_called_once()
            boot.assert_not_called()

    def recover(self, directory, results):
        observed = []
        def probe(*args):
            observed.append((args[2], os.environ['IOS_SIMULATOR_UDID']))
            result = results.pop(0)
            if result is not None:
                raise result
        def boot():
            os.environ['IOS_SIMULATOR_UDID'] = 'fresh-owned-device'
        with patch.dict(os.environ, {'IOS_SIMULATOR_UDID': 'first-owned-device',
                                    'DEVELOPER_DIR': '/Xcode/Developer'}, clear=True), \
             patch.object(ios_control_runner, 'probe', side_effect=probe), \
             patch.object(ios_control_runner.ios_simulator, 'main', side_effect=boot) as create, \
             patch.object(ios_control_runner.subprocess, 'run') as run:
            ios_control_runner.verify(self.app(directory), Path(directory))
            create.assert_called_once()
            self.assertEqual(run.call_args.args[0][-1], 'fresh-owned-device')
        return observed

    def test_vm_failure_retries_once_with_new_device_and_distinct_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            observed = self.recover(directory, [SystemExit('VM not ready'), None])
            self.assertEqual(observed, [('ios-control', 'first-owned-device'),
                                        ('ios-control-recovery', 'fresh-owned-device')])
            self.assertTrue((Path(directory) / 'ios-control-recovery-shutdown.log').exists())

    def test_second_vm_failure_stays_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(SystemExit, 'still not ready'):
                self.recover(directory, [SystemExit('first'), SystemExit('still not ready')])

    def test_lokal_app_is_never_eligible_for_control_recovery(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(ios_control_runner, 'probe') as probe:
            with self.assertRaises(ValueError):
                ios_control_runner.verify(self.app(directory, 'app.lokal.mobile'), Path(directory))
            probe.assert_not_called()

    def test_installation_errors_propagate_without_recovery(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(ios_control_runner, 'probe', side_effect=subprocess.CalledProcessError(1, 'install')), \
             patch.object(ios_control_runner.ios_simulator, 'main') as boot:
            with self.assertRaises(subprocess.CalledProcessError):
                ios_control_runner.verify(self.app(directory), Path(directory))
            boot.assert_not_called()


if __name__ == '__main__':
    unittest.main()
