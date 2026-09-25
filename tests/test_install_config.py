# SPDX-License-Identifier: LGPL-2.1-or-later
"""Offline installation must preserve unrelated settings and symlink targets."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', ROOT / 'scripts/install_crossover_entry.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
SECTION = r'[Software\\Microsoft\\Windows\\CurrentVersion\\RunServices]'
VALUE = r'"WineLsassCompat"="C:\\windows\\system32\\lsass.exe"'


class InstallConfiguration(unittest.TestCase):
    def test_preserves_settings_and_external_symlink(self):
        for existing in (False, True):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                prefix, runtime = root / 'prefix', root / 'runtime'
                system32 = prefix / 'drive_c/windows/system32'
                system32.mkdir(parents=True)
                modules = runtime / 'lib/wine/x86_64-windows'
                modules.mkdir(parents=True)
                (modules / 'lsass.exe').write_bytes(b'new-component')
                original = root / 'original-component.exe'
                original.write_bytes(b'original-unchanged')
                (system32 / 'lsass.exe').symlink_to(original)
                startup = (SECTION + ' 123\n"OtherService"="keep.exe"\n'
                           '"WineLsassCompat"="old.exe"\n\n') if existing else ''
                registry = ('WINE REGISTRY Version 2\n\n' + startup +
                            '[Software\\\\Unrelated] 456\n"Keep"="value"\n')
                path = prefix / 'system.reg'
                path.write_text(registry)
                installer.install_system_process(prefix, runtime)
                installer.install_system_process(prefix, runtime)
                result = path.read_text()
                self.assertEqual(result.count(SECTION), 1)
                self.assertEqual(result.count(VALUE), 1)
                self.assertNotIn('"WineLsassCompat"="old.exe"', result)
                self.assertIn('[Software\\\\Unrelated] 456\n"Keep"="value"', result)
                if existing: self.assertIn('"OtherService"="keep.exe"', result)
                self.assertEqual(original.read_bytes(), b'original-unchanged')
                self.assertFalse((system32 / 'lsass.exe').is_symlink())
                self.assertEqual((system32 / 'lsass.exe').read_bytes(), b'new-component')


if __name__ == '__main__':
    unittest.main()
