import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from app_version import MAJOR, resolve, version


class AppVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q', '-b', 'develop')

    def git(self, *arguments):
        environment = {**os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
        return subprocess.check_output(['git', '-C', str(self.root), '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                                        '-c', 'commit.gpgsign=false', *arguments], text=True, env=environment).strip()

    def commit(self, message):
        self.git('commit', '-q', '--allow-empty', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def merge_feature(self, name, commits):
        self.git('switch', '-q', '-c', name)
        for index in range(commits):
            self.commit(f'{name} {index}')
        self.git('switch', '-q', 'develop')
        self.git('merge', '-q', '--no-ff', '-m', f'{name} merge', name)
        return self.git('rev-parse', 'HEAD')

    def test_minor_counts_merges_into_develop_and_build_counts_commits(self):
        self.commit('initial')
        self.assertEqual(version(self.root), f'{MAJOR}.0.1')
        self.merge_feature('feature/a', 2)          # 2 commits + merge
        self.assertEqual(version(self.root), f'{MAJOR}.1.4')
        # A merge inside a feature branch is not a merge into develop.
        self.git('switch', '-q', '-c', 'feature/b')
        self.commit('b 0')
        self.git('switch', '-q', '-c', 'feature/b-part')
        self.commit('part 0')
        self.git('switch', '-q', 'feature/b')
        self.git('merge', '-q', '--no-ff', '-m', 'part merge', 'feature/b-part')
        self.git('switch', '-q', 'develop')
        self.git('merge', '-q', '--no-ff', '-m', 'b merge', 'feature/b')
        self.assertEqual(version(self.root), f'{MAJOR}.2.8')
        self.commit('direct commit on develop')
        self.assertEqual(version(self.root), f'{MAJOR}.2.9')

    def test_raising_major_restarts_minor_but_not_build(self):
        self.commit('initial')
        start = self.merge_feature('feature/a', 1)
        self.merge_feature('feature/b', 1)
        self.assertEqual(version(self.root, major=1, major_start=start), '1.1.5')
        self.assertEqual(version(self.root, major=1, major_start=None), '1.2.5')

    def test_override_and_missing_history(self):
        with patch.dict(os.environ, {'LCMP_VERSION': '2.3.4'}):
            self.assertEqual(resolve(self.root), '2.3.4')
        with patch.dict(os.environ, {'LCMP_VERSION': '2.3'}), self.assertRaises(ValueError):
            resolve(self.root)
        with tempfile.TemporaryDirectory() as plain, patch.dict(os.environ, {'LCMP_VERSION': ''}):
            self.assertEqual(resolve(Path(plain)), f'{MAJOR}.0.0')


if __name__ == '__main__':
    unittest.main()
