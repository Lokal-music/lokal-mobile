"""The release package must load its SMB dylib, not merely contain it."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from ios_package import inspect_smb


class SmbLoadGraphTests(unittest.TestCase):
    def test_requires_reachable_framework_and_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            executable = app / 'Runner'
            plugin = app / 'Frameworks/dart_smb2.framework/dart_smb2'
            native = app / 'Frameworks/libsmb2.framework/libsmb2'
            notice = app / 'Frameworks/App.framework/flutter_assets/assets/licenses/libsmb2.txt'
            notice.parent.mkdir(parents=True)
            notice.write_text('LGPL')
            outputs = {str(executable): 'Runner:\n @rpath/dart_smb2.framework/dart_smb2 (compatibility version 1)\n',
                       str(plugin): 'plugin:\n @rpath/libsmb2.framework/libsmb2 (compatibility version 1)\n',
                       str(native): 'native:\n /usr/lib/libSystem.B.dylib (compatibility version 1)\n'}
            with patch('ios_package.command', side_effect=lambda *args: outputs[args[-1]]):
                self.assertTrue(inspect_smb(app, executable, [executable, plugin, native])['ffi_load_reachable'])
                outputs[str(plugin)] = 'plugin:\n /usr/lib/libSystem.B.dylib (compatibility version 1)\n'
                with self.assertRaisesRegex(ValueError, 'not loaded'):
                    inspect_smb(app, executable, [executable, plugin, native])
                notice.unlink()
                with self.assertRaisesRegex(ValueError, 'notice'):
                    inspect_smb(app, executable, [executable, plugin, native])


if __name__ == '__main__': unittest.main()
