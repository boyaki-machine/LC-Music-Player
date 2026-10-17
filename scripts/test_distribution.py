import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch
from distribution import clean_revision, copy_files, inventory, main, project_files, verify, write_json
from project_license import bundle as bundle_project_license
import plistlib
from signing import ENTITLEMENTS, sign_app


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_manifest_detects_tampering_missing_and_extra_files(self):
        (self.root / 'source').write_bytes(b'Exact corresponding source\n')
        expected = inventory(self.root)
        write_json(self.root / 'SHA256SUMS.json', expected)
        self.assertEqual(verify(self.root), 1)
        (self.root / 'source').write_bytes(b'Truncated')
        with self.assertRaises(ValueError): verify(self.root)
        (self.root / 'source').unlink()
        with self.assertRaises(ValueError): verify(self.root)
        (self.root / 'source').write_bytes(b'Exact corresponding source\n')
        (self.root / 'extra').write_text('Unrecorded')
        with self.assertRaises(ValueError): verify(self.root)

    def test_framework_symlinks_preserved_and_escape_rejected(self):
        versions = self.root / 'Versions'; versions.mkdir()
        (versions / 'A').mkdir(); (versions / 'A/library').write_bytes(b'Mach-O fixture')
        (versions / 'Current').symlink_to('A')
        (self.root / 'library').symlink_to('Versions/Current/library')
        expected = inventory(self.root)
        self.assertEqual(expected['Versions/Current'], {'symlink': 'A'})
        write_json(self.root / 'SHA256SUMS.json', expected)
        verify(self.root)
        (self.root / 'library').unlink(); (self.root / 'library').symlink_to('/etc/hosts')
        with self.assertRaises(ValueError): verify(self.root)

    def test_source_snapshot_copies_exact_bytes_without_git_or_external_links(self):
        source = self.root / 'source'; source.mkdir()
        (source / 'COPYING').write_bytes(b'Original\r\n')
        target = self.root / 'snapshot'
        copy_files(source, ['COPYING'], target)
        self.assertEqual((target / 'COPYING').read_bytes(), b'Original\r\n')
        for name in ['../outside', '.git/config', str(source / 'COPYING')]:
            with self.assertRaises(ValueError): copy_files(source, [name], target)
        (source / 'link').symlink_to('/etc/hosts')
        with self.assertRaises(ValueError): copy_files(source, ['link'], target)

    def git(self, *arguments):
        return subprocess.check_output(['git', '-C', str(self.root), '-c', 'user.name=LCMP fixture',
            '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
            '-c', 'core.hooksPath=/dev/null', *arguments], text=True).strip()

    def test_dependency_snapshot_rejects_wrong_revision_dirty_and_untracked_code(self):
        self.git('init', '-q')
        original = self.root / 'source.c'; original.write_text('Original library')
        self.git('add', 'source.c'); self.git('commit', '-qm', 'Fixture')
        revision = self.git('rev-parse', 'HEAD')
        clean_revision(self.root, revision)
        with self.assertRaises(ValueError): clean_revision(self.root, '0' * 40)
        original.write_text('Changed without commit')
        with self.assertRaises(ValueError): clean_revision(self.root, revision)
        original.write_text('Original library')
        (self.root / 'unexpected.c').write_text('Unrecorded compilation input')
        with self.assertRaises(ValueError): clean_revision(self.root, revision)

    def test_project_snapshot_excludes_local_notes_credentials_and_editor_files(self):
        self.git('init', '-q')
        for name in ['Package.swift', 'scripts/new.py', '.vscode/settings.json',
                     'LEARNINGS_CODEX.md', 'DEVELOPMENT_NOTES.md', '.codex/config.toml', '.env']:
            path = self.root / name; path.parent.mkdir(exist_ok=True)
            path.write_text('fixture')
        with patch('distribution.ROOT', self.root):
            self.assertEqual(project_files(), ['Package.swift', 'scripts/new.py'])

    def test_changed_dependency_lock_is_rejected_before_fetch_or_build(self):
        (self.root / 'Package.resolved').write_text('New dependency graph')
        config = self.root / 'third-party/distribution.json'; config.parent.mkdir()
        write_json(config, {'schemaVersion': 1, 'resolvedSHA256': '0' * 64})
        with patch('distribution.ROOT', self.root), patch('sys.argv',
                ['distribution.py', '--output', str(self.root / 'output')]), patch('subprocess.run') as run:
            with self.assertRaises(ValueError): main()
            run.assert_not_called()
        self.assertFalse((self.root / 'output').exists())

    def test_project_license_is_exact_and_invalid_documents_do_not_replace_previous_copy(self):
        source = self.root / 'project'; source.mkdir()
        license_text = (Path(__file__).resolve().parent.parent / 'LICENSE').read_bytes()
        (source / 'LICENSE').write_bytes(license_text)
        (source / 'NOTICE').write_bytes(b'LCMP copyright and third-party boundary\n')
        target = self.root / 'bundle'
        bundle_project_license(source, target)
        self.assertEqual((target / 'LICENSE').read_bytes(), license_text)
        original_notice = (target / 'NOTICE').read_bytes()
        (source / 'LICENSE').write_bytes(license_text + b'Additional restriction\n')
        with self.assertRaises(ValueError): bundle_project_license(source, target)
        self.assertEqual((target / 'LICENSE').read_bytes(), license_text)
        (source / 'LICENSE').write_bytes(license_text)
        (source / 'NOTICE').write_bytes(b'\n')
        with self.assertRaises(ValueError): bundle_project_license(source, target)
        self.assertEqual((target / 'NOTICE').read_bytes(), original_notice)
        (source / 'LICENSE').unlink()
        with self.assertRaises(FileNotFoundError): bundle_project_license(source, target)

    def test_app_signature_uses_hardened_runtime_with_only_library_validation_relaxed(self):
        self.assertEqual(ENTITLEMENTS, {'com.apple.security.cs.disable-library-validation': True})
        seen = []
        def record(command, check):
            self.assertTrue(check)
            if '--entitlements' in command:
                seen.append(plistlib.loads(Path(command[command.index('--entitlements') + 1]).read_bytes()))
            seen.append(command)
        with patch('subprocess.run', side_effect=record):
            sign_app(self.root / 'LCMP.app')
        self.assertEqual(seen[0], ENTITLEMENTS)
        self.assertEqual(seen[1][:6], ['codesign', '--force', '--sign', '-', '--options', 'runtime'])
        self.assertEqual(seen[2], ['codesign', '--verify', '--deep', '--strict', str(self.root / 'LCMP.app')])


if __name__ == '__main__':
    unittest.main()
