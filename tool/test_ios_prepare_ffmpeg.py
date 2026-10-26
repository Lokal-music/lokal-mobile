"""Archive transport/integrity contracts; no live dependency download."""
import hashlib
import http.client
import io
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import Mock

from ios_prepare_ffmpeg import download_verified


class FFmpegArchiveTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / 'native.zip'
        self.payload = b'controlled native archive bytes'
        self.sha = hashlib.sha256(self.payload).hexdigest()
        self.pause = Mock()

    def download(self, opener):
        download_verified('https://example.test/pinned.zip', self.archive,
                          self.sha, opener=opener, pause=self.pause)

    def test_gateway_timeout_retries_same_archive_then_checks_digest(self):
        opener = Mock(side_effect=[urllib.error.HTTPError(
            'https://example.test/pinned.zip', 504, 'Gateway timeout', {}, None),
            io.BytesIO(self.payload)])
        self.download(opener)
        self.assertEqual(opener.call_count, 2)
        self.assertEqual(opener.call_args_list[0], opener.call_args_list[1])
        self.assertEqual(self.archive.read_bytes(), self.payload)
        self.assertFalse(self.archive.with_name('native.zip.part').exists())
        self.pause.assert_called_once_with(2)

    def test_partial_response_is_replaced_without_reusing_truncated_prefix(self):
        class PartialResponse(io.BytesIO):
            def read(self, *args):
                if self.tell():
                    raise http.client.IncompleteRead(b'partial')
                return super().read(4)
        opener = Mock(side_effect=[PartialResponse(b'truncated'), io.BytesIO(self.payload)])
        self.download(opener)
        self.assertEqual(self.archive.read_bytes(), self.payload)
        self.assertEqual(opener.call_count, 2)

    def test_bad_digest_is_fatal_and_never_publishes_or_retries(self):
        opener = Mock(return_value=io.BytesIO(b'incorrect archive'))
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.download(opener)
        opener.assert_called_once()
        self.pause.assert_not_called()
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.archive.with_name('native.zip.part').exists())

    def test_permanent_http_error_is_not_retried(self):
        opener = Mock(side_effect=urllib.error.HTTPError(
            'https://example.test/pinned.zip', 404, 'Not found', {}, None))
        with self.assertRaises(urllib.error.HTTPError):
            self.download(opener)
        opener.assert_called_once()
        self.pause.assert_not_called()
        self.assertFalse(self.archive.exists())

    def test_repeated_transport_failure_exhausts_bound_without_an_archive(self):
        opener = Mock(side_effect=TimeoutError('socket timed out'))
        with self.assertRaises(TimeoutError):
            self.download(opener)
        self.assertEqual(opener.call_count, 3)
        self.assertEqual(self.pause.call_count, 2)
        self.assertFalse(self.archive.exists())

    def test_reuse_requires_rechecking_cached_bytes(self):
        self.archive.write_bytes(self.payload)
        opener = Mock()
        self.download(opener)
        opener.assert_not_called()
        self.archive.write_bytes(b'tampered cache')
        opener.return_value = io.BytesIO(self.payload)
        self.download(opener)
        opener.assert_called_once()
        self.assertEqual(self.archive.read_bytes(), self.payload)


if __name__ == '__main__':
    unittest.main()
