import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ios_resources  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


class IOSResourcesTests(unittest.TestCase):
    def run_phase(self, app, *options):
        with mock.patch.dict(os.environ, {'LCMP_VERSION': '1.4.80'}), \
                mock.patch.object(sys, 'argv', ['ios_resources.py', *options, str(app)]), \
                mock.patch('builtins.print'):
            ios_resources.main()

    def test_bundles_license_and_stamps_version(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'LCMP.app'
            app.mkdir()
            with (app / 'Info.plist').open('wb') as file:
                plistlib.dump({'CFBundleIdentifier': 'io.github.boyaki-machine.LC-Music-Player', 'CFBundleShortVersionString': '1.0.0'},
                              file, fmt=plistlib.FMT_BINARY)
            self.run_phase(app)
            self.assertEqual((app / 'LCMPLicense/LICENSE').read_bytes(), (ROOT / 'LICENSE').read_bytes())
            self.assertEqual((app / 'LCMPLicense/NOTICE').read_bytes(), (ROOT / 'NOTICE').read_bytes())
            self.assertIn('"packages": []', (app / 'ThirdPartyLicenses/index.json').read_text())
            with (app / 'Info.plist').open('rb') as file:
                info = plistlib.load(file)
            self.assertEqual(info['CFBundleShortVersionString'], '1.4.80')
            self.assertEqual(info['CFBundleVersion'], '1.4.80')
            self.assertEqual(info['CFBundleIdentifier'], 'io.github.boyaki-machine.LC-Music-Player')

    def test_extension_gets_the_version_without_licenses(self):
        with tempfile.TemporaryDirectory() as folder:
            extension = Path(folder) / 'LCMPWidgets.appex'
            extension.mkdir()
            with (extension / 'Info.plist').open('wb') as file:
                plistlib.dump({'CFBundleShortVersionString': '1.0.0'}, file, fmt=plistlib.FMT_BINARY)
            self.run_phase(extension, '--version-only')
            self.assertFalse((extension / 'LCMPLicense').exists())
            self.assertFalse((extension / 'ThirdPartyLicenses').exists())
            with (extension / 'Info.plist').open('rb') as file:
                info = plistlib.load(file)
            self.assertEqual(info['CFBundleShortVersionString'], '1.4.80')
            self.assertEqual(info['CFBundleVersion'], '1.4.80')

    def test_project_runs_the_phase_after_the_info_plist(self):
        project = (ROOT / 'iOS/LCMPiOS.xcodeproj/project.pbxproj').read_text()
        self.assertIn('scripts/ios_resources.py', project)
        self.assertIn('"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"', project)
        self.assertIn('scripts/ios_resources.py\\" --version-only', project)


if __name__ == '__main__':
    unittest.main()
