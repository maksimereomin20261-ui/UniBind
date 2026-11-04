import tempfile
import unittest
import zipfile
from pathlib import Path

# test_launcher provides a tkinter shim on non-Windows hosts.
import test_launcher  # noqa: F401
from verify_package import REQUIRED, verify


class PackageVerificationTests(unittest.TestCase):
    def test_complete_and_missing_tray(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'package.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                for name in REQUIRED:
                    z.writestr(name, b'data')
            verify(archive)
            with zipfile.ZipFile(archive, 'w') as z:
                for name in REQUIRED:
                    if name != 'ui/tray.html':
                        z.writestr(name, b'data')
            with self.assertRaises(ValueError):
                verify(archive)
