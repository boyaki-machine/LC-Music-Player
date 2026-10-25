from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import signing  # noqa: E402

IDENTITY = 'Developer ID Application: Example Developer (ABCDE12345)'


class SettingsTests(unittest.TestCase):
    def read(self, text=None, environ=None):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / signing.SETTINGS_FILE.name
            if text is not None:
                path.write_text(text)
            return signing.read_settings(path, environ or {})

    def test_without_settings_the_app_is_signed_ad_hoc(self):
        settings = self.read()
        self.assertEqual(settings, signing.Settings())
        self.assertFalse(settings.developer_id)
        self.assertEqual(settings.describe(), 'ad-hoc')

    def test_reads_the_identity_and_the_notary_profile(self):
        settings = self.read(f'// Developer ID signing\n\nLCMP_SIGNING_IDENTITY = {IDENTITY}\n'
                             'LCMP_NOTARY_PROFILE = "LCMP-notary"\n')
        self.assertEqual(settings, signing.Settings(IDENTITY, 'LCMP-notary'))
        self.assertTrue(settings.developer_id)
        self.assertNotIn('Example', settings.describe())

    def test_environment_overrides_the_file(self):
        text = f'LCMP_SIGNING_IDENTITY = {IDENTITY}\nLCMP_NOTARY_PROFILE = LCMP-notary\n'
        self.assertEqual(self.read(text, {'LCMP_NOTARY_PROFILE': 'other'}).notary_profile, 'other')
        # An empty value turns Developer ID signing off without editing the file.
        self.assertEqual(self.read(f'LCMP_SIGNING_IDENTITY = {IDENTITY}\n', {'LCMP_SIGNING_IDENTITY': ''}),
                         signing.Settings())
        self.assertEqual(self.read(None, {'LCMP_SIGNING_IDENTITY': IDENTITY}).identity, IDENTITY)

    def test_rejects_broken_lines_and_unknown_settings(self):
        with self.assertRaisesRegex(ValueError, r':2: expected KEY = VALUE'):
            self.read(f'LCMP_SIGNING_IDENTITY = {IDENTITY}\nLCMP_NOTARY_PROFILE\n')
        with self.assertRaisesRegex(ValueError, 'unknown setting LCMP_SIGNING_IDENTITIY'):
            self.read(f'LCMP_SIGNING_IDENTITIY = {IDENTITY}\n')

    def test_a_notary_profile_needs_an_identity(self):
        with self.assertRaisesRegex(ValueError, 'needs LCMP_SIGNING_IDENTITY'):
            self.read('LCMP_NOTARY_PROFILE = LCMP-notary\n')

    def test_settings_file_is_not_tracked(self):
        ignored = (ROOT / '.gitignore').read_text().splitlines()
        self.assertIn(f'/{signing.SETTINGS_FILE.name}', ignored)


class CodesignTests(unittest.TestCase):
    def test_ad_hoc_signature_takes_no_key_and_no_timestamp(self):
        self.assertEqual(signing.codesign_command(Path('LCMP.app'), signing.Settings(), timestamp=True),
                         ['codesign', '--force', '--sign', '-', 'LCMP.app'])

    def test_developer_id_contacts_the_timestamp_server_only_for_distribution(self):
        settings = signing.Settings(IDENTITY)
        self.assertEqual(signing.codesign_command(Path('x.bundle'), settings),
                         ['codesign', '--force', '--sign', IDENTITY, '--timestamp=none', 'x.bundle'])
        self.assertEqual(signing.codesign_command(Path('x.dmg'), settings, timestamp=True),
                         ['codesign', '--force', '--sign', IDENTITY, '--timestamp', 'x.dmg'])

    def test_the_app_gets_the_hardened_runtime_and_the_sandbox(self):
        command = signing.codesign_command(Path('LCMP.app'), signing.Settings(IDENTITY), True, Path('e.plist'))
        self.assertEqual(command[-6:], ['--timestamp', '--options', 'runtime', '--entitlements', 'e.plist', 'LCMP.app'])
        self.assertTrue(signing.ENTITLEMENTS['com.apple.security.app-sandbox'])
        self.assertNotIn('com.apple.security.cs.disable-library-validation', signing.ENTITLEMENTS)

    def test_requirement_names_the_configured_certificate(self):
        by_name = signing.requirement(signing.Settings(IDENTITY))
        self.assertTrue(by_name.startswith('anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]'))
        self.assertTrue(by_name.endswith(f'certificate leaf[subject.CN] = "{IDENTITY}"'))
        by_hash = signing.requirement(signing.Settings('ab' * 20))
        self.assertTrue(by_hash.endswith('certificate leaf = H"' + 'AB' * 20 + '"'))


class BuildTests(unittest.TestCase):
    def test_app_uses_the_shared_bundle_identifier(self):
        source = (ROOT / 'scripts/build-app.py').read_text()
        self.assertIn('BUNDLE_IDENTIFIER = "io.github.boyaki-machine.LC-Music-Player"', source)
        self.assertIn('"CFBundleIdentifier": BUNDLE_IDENTIFIER', source)
        shared = (ROOT / 'iOS/Shared.xcconfig').read_text()
        self.assertIn('LCMP_BUNDLE_ID = io.github.boyaki-machine.LC-Music-Player\n', shared)


if __name__ == '__main__':
    unittest.main()
