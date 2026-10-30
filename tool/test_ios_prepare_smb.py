"""Portable checks of SMB dependency validation; not Apple runtime acceptance."""
import struct
import unittest
from ios_prepare_smb import inspect_binary


def macho(*, platform=2, cpu=0x100000c, dependency='/usr/lib/libSystem.B.dylib', symbol='smb2_init_context'):
    def dylib(command, text):
        data = text.encode() + b'\0'
        length = (24 + len(data) + 7) // 8 * 8
        return struct.pack('<6I', command, length, 24, 0, 0, 0) + data.ljust(length - 24, b'\0')
    commands = [struct.pack('<6I', 0x32, 24, platform, 12 << 16, 16 << 16, 0),
                dylib(0xd, '@rpath/libsmb2.framework/libsmb2'), dylib(0xc, dependency)]
    size = sum(map(len, commands)) + 24
    offset = 32 + size
    strings = b'\0_' + symbol.encode() + b'\0'
    commands.append(struct.pack('<6I', 2, 24, offset, 1, offset + 16, len(strings)))
    return (struct.pack('<8I', 0xfeedfacf, cpu, 0, 6, len(commands), size, 0, 0) +
            b''.join(commands) + struct.pack('<IBBHQ', 1, 0xf, 1, 0, 0) + strings)


class SmbBinaryTests(unittest.TestCase):
    def inspect(self, data):
        inspect_binary(data, platform=2, architectures={0x100000c}, symbols={'smb2_init_context'})

    def test_accepts_device_dynamic_framework(self): self.inspect(macho())

    def test_refuses_simulator_in_device_slice(self):
        with self.assertRaisesRegex(ValueError, 'platform'): self.inspect(macho(platform=7))

    def test_refuses_host_architecture(self):
        with self.assertRaisesRegex(ValueError, 'architecture'): self.inspect(macho(cpu=0x1000007))

    def test_refuses_unbundled_dependency(self):
        with self.assertRaisesRegex(ValueError, 'dependency'): self.inspect(macho(dependency='/opt/homebrew/lib/libcrypto.dylib'))

    def test_refuses_missing_ffi_export(self):
        with self.assertRaisesRegex(ValueError, 'FFI'): self.inspect(macho(symbol='different_function'))

    def test_refuses_truncated_command(self):
        with self.assertRaises(ValueError): self.inspect(macho()[:40])


if __name__ == '__main__': unittest.main()
