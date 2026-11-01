"""The iPhone app's App Store declarations: privacy manifests, the encryption answer and the export options."""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SUFFIXES = {'.swift', '.c', '.h', '.m'}
# The categories of Apple's required reason APIs and the calls that need them.
# A category is declared exactly when the code that goes into the bundle uses one of its calls.
REQUIRED_REASON_APIS = {
    'NSPrivacyAccessedAPICategoryUserDefaults': r'\bUserDefaults\b|\bNSUserDefaults\b|@AppStorage',
    'NSPrivacyAccessedAPICategoryFileTimestamp':
        r'\bcreationDate\b|modificationDate\b|\bst_[mca]timespec\b|\bst_[mca]tim\b|\bst_birthtime|\bgetattrlist\b',
    'NSPrivacyAccessedAPICategorySystemBootTime':
        r'\bsystemUptime\b|\bmach_absolute_time\b|\bmach_continuous_time\b|kern\.boottime',
    'NSPrivacyAccessedAPICategoryDiskSpace':
        r'volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|systemSize\b|\bstatv?fs\b|NSFileSystemFreeSize',
    'NSPrivacyAccessedAPICategoryActiveKeyboards': r'\bactiveInputModes\b',
}
# What each bundle is built from. The app links every shared module except the macOS app.
BUNDLES = {
    'app': (ROOT / 'iOS/LCMPiOS/PrivacyInfo.xcprivacy',
            [p for p in (ROOT / 'Sources').iterdir() if p.is_dir() and p.name != 'LCMPApp']
            + [ROOT / 'iOS/LCMPiOS', ROOT / 'iOS/Shared']),
    'widgets': (ROOT / 'iOS/LCMPWidgets/PrivacyInfo.xcprivacy',
                [ROOT / 'Sources/ControlSurfaces', ROOT / 'iOS/LCMPWidgets', ROOT / 'iOS/Shared']),
}
EXPECTED_REASONS = {
    'app': {
        'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1', '1C8F.1'},
        'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1', '3B52.1'},
        'NSPrivacyAccessedAPICategorySystemBootTime': {'35F9.1'},
    },
    'widgets': {
        'NSPrivacyAccessedAPICategoryUserDefaults': {'1C8F.1'},
    },
}


def load(path):
    with path.open('rb') as file:
        return plistlib.load(file)


def declared_reasons(manifest):
    return {entry['NSPrivacyAccessedAPIType']: set(entry['NSPrivacyAccessedAPITypeReasons'])
            for entry in manifest['NSPrivacyAccessedAPITypes']}


def used_categories(folders):
    used = set()
    for folder in folders:
        for path in folder.rglob('*'):
            if path.suffix not in SOURCE_SUFFIXES:
                continue
            text = path.read_text(errors='replace')
            used.update(category for category, pattern in REQUIRED_REASON_APIS.items() if re.search(pattern, text))
    return used


class PrivacyManifestTests(unittest.TestCase):
    def test_manifests_declare_no_tracking_and_no_collected_data(self):
        for name, (path, _) in BUNDLES.items():
            with self.subTest(name):
                manifest = load(path)
                self.assertIs(manifest['NSPrivacyTracking'], False)
                self.assertEqual(manifest['NSPrivacyTrackingDomains'], [])
                self.assertEqual(manifest['NSPrivacyCollectedDataTypes'], [])

    def test_manifests_give_the_reasons_for_the_apis_in_use(self):
        for name, (path, _) in BUNDLES.items():
            with self.subTest(name):
                self.assertEqual(declared_reasons(load(path)), EXPECTED_REASONS[name])

    def test_declared_categories_match_the_code(self):
        # A new use of a required reason API must be added to the manifest, and a removed one taken out.
        for name, (path, folders) in BUNDLES.items():
            with self.subTest(name):
                self.assertEqual(set(declared_reasons(load(path))), used_categories(folders))

    def test_manifests_sit_in_folders_the_project_bundles(self):
        project = (ROOT / 'iOS/LCMPiOS.xcodeproj/project.pbxproj').read_text()
        for folder in ('LCMPiOS', 'LCMPWidgets'):
            self.assertRegex(project, rf'isa = PBXFileSystemSynchronizedRootGroup; path = {folder};')


class StoreSettingsTests(unittest.TestCase):
    def test_app_declares_only_exempt_encryption(self):
        # CryptoKit only hashes, so App Store Connect need not ask about export compliance.
        self.assertIs(load(ROOT / 'iOS/LCMPiOS-Info.plist')['ITSAppUsesNonExemptEncryption'], False)

    def test_export_uploads_to_app_store_connect_without_changing_the_version(self):
        options = load(ROOT / 'iOS/ExportOptions.plist')
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertEqual(options['destination'], 'upload')
        self.assertEqual(options['signingStyle'], 'automatic')
        # The version comes from Git (scripts/ios_resources.py); Xcode must not renumber the build.
        self.assertIs(options['manageAppVersionAndBuildNumber'], False)
        self.assertNotIn('teamID', options)


if __name__ == '__main__':
    unittest.main()
