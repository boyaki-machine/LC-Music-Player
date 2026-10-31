from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import python_requirement  # noqa: E402

# Xcode's build phases of the iPhone app run `python3` from Xcode's own PATH, often macOS's /usr/bin/python3.
SYSTEM_PYTHON = Path('/usr/bin/python3')


class PythonRequirementTests(unittest.TestCase):
    def test_an_old_python_stops_with_a_message(self):
        with self.assertRaises(SystemExit) as raised:
            python_requirement.require((3, 9))
        self.assertIn('Python 3.12 or later is required', str(raised.exception))
        self.assertIn('3.9', str(raised.exception))

    def test_the_minimum_and_newer_pass(self):
        for version in [python_requirement.MINIMUM, (3, 14), (4, 0)]:
            python_requirement.require(version)

    @unittest.skipUnless(SYSTEM_PYTHON.exists(), 'no /usr/bin/python3')
    def test_the_system_python_reaches_the_message_and_still_runs_the_iphone_build_phase(self):
        # The signing module is where the macOS build first needs the newer Python.
        old = subprocess.run([SYSTEM_PYTHON, '-c', 'import sys; print(sys.version_info < (3, 12))'],
                             capture_output=True, text=True, check=True).stdout.strip() == 'True'
        signing = subprocess.run([SYSTEM_PYTHON, '-c', 'import signing'], cwd=ROOT / 'scripts', capture_output=True, text=True)
        if old:
            self.assertNotEqual(signing.returncode, 0)
            self.assertIn('Python 3.12 or later is required', signing.stderr)
        else:
            self.assertEqual(signing.returncode, 0, signing.stderr)
        phase = subprocess.run([SYSTEM_PYTHON, '-c', 'import ios_resources'], cwd=ROOT / 'scripts', capture_output=True, text=True)
        self.assertEqual(phase.returncode, 0, phase.stderr)


if __name__ == '__main__':
    unittest.main()
