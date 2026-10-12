#!/usr/bin/env python3
"""Offline tests for APK byte accounting; fixtures are generated in temp dirs."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

from apk_size_report import analyze, category


class ApkSizeReportTest(unittest.TestCase):
    def test_categories(self):
        for name, expected in {
            'lib/arm64-v8a/libapp.so': 'native/arm64-v8a',
            'lib/x86_64/libflutter.so': 'native/x86_64',
            'assets/flutter_assets/a.json': 'flutter_assets',
            'classes2.dex': 'dex',
            'res/drawable/icon.xml': 'android_resources',
            'resources.arsc': 'android_resources',
            'META-INF/CERT.RSA': 'metadata',
            'AndroidManifest.xml': 'other',
        }.items():
            self.assertEqual(category(name), expected)

    def test_byte_accounting_and_read_only(self):
        with tempfile.TemporaryDirectory() as root:
            apk = Path(root) / 'test.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('lib/arm64-v8a/libapp.so', b'a' * 20000,
                                 compress_type=zipfile.ZIP_DEFLATED)
                archive.writestr('classes.dex', b'dex')
                archive.writestr('assets/', b'')
            original = hashlib.sha256(apk.read_bytes()).digest()
            report = analyze(apk)
            self.assertEqual(report['actual_bytes'], apk.stat().st_size)
            self.assertEqual(report['entries'], 2)
            self.assertEqual(report['uncompressed_content_bytes'], 20003)
            self.assertGreater(report['container_overhead_bytes'], 0)
            self.assertEqual(report['actual_bytes'],
                             report['compressed_content_bytes'] +
                             report['container_overhead_bytes'])
            self.assertEqual(sum(g['files'] for g in report['categories'].values()), 2)
            self.assertEqual(hashlib.sha256(apk.read_bytes()).digest(), original)
            out = Path(root) / 'reports' / 'size.json'
            subprocess.run([sys.executable, str(Path(__file__).with_name(
                'apk_size_report.py')), str(apk), '--out', str(out)],
                check=True, capture_output=True)
            self.assertEqual(json.loads(out.read_text()), report)

    def test_bad_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            apk = Path(root) / 'broken.apk'
            apk.write_bytes(b'not a ZIP archive')
            with self.assertRaises(zipfile.BadZipFile):
                analyze(apk)


if __name__ == '__main__':
    unittest.main()
