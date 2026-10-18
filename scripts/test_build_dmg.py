import importlib.util
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_dmg', ROOT / 'scripts/build-dmg.py')
build_dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_dmg)


class BuildDMGTests(unittest.TestCase):
    def test_background_has_standard_and_retina_images(self):
        info = subprocess.check_output(['tiffutil', '-info', str(build_dmg.BACKGROUND)], text=True)
        sizes = [tuple(map(int, size)) for size in re.findall(r'Image Width: (\d+) Image Length: (\d+)', info)]
        width, height = build_dmg.WINDOW
        self.assertEqual(sizes, [(width, height), (width * 2, height * 2)])
        self.assertEqual(re.findall(r'Resolution: (\d+), \d+', info), ['72', '144'])

    def test_renderer_draws_for_the_finder_layout(self):
        source = (ROOT / 'scripts/render-dmg-background.swift').read_text()
        self.assertIn(f'let width: CGFloat = {build_dmg.WINDOW[0]}, height: CGFloat = {build_dmg.WINDOW[1]}', source)
        self.assertIn('appCentre = CGPoint(x: %d, y: %d)' % build_dmg.APP_POSITION, source)
        self.assertIn('applicationsCentre = CGPoint(x: %d, y: %d)' % build_dmg.APPLICATIONS_POSITION, source)
        self.assertIn(f'appCentre.y + {build_dmg.ICON_SIZE // 2} +', source)

    def test_applescript_places_the_icons_over_the_background(self):
        script = build_dmg.applescript('LC Music Player 0.1.2')
        left, top = build_dmg.WINDOW_ORIGIN
        right, bottom = left + build_dmg.WINDOW[0], top + build_dmg.WINDOW[1] + build_dmg.TITLE_BAR
        self.assertIn('tell disk "LC Music Player 0.1.2"', script)
        self.assertIn(f'set bounds of container window to {{{left}, {top}, {right}, {bottom}}}', script)
        self.assertIn(f'set icon size of options to {build_dmg.ICON_SIZE}', script)
        self.assertIn('set background picture of options to file ".background:background.tiff"', script)
        self.assertIn('set position of item "LCMP.app" of container window to {170, 176}', script)
        self.assertIn('set position of item "Applications" of container window to {470, 176}', script)
        for bar in ['toolbar', 'statusbar', 'pathbar']:
            self.assertIn(f'set {bar} visible of container window to false', script)

    def test_names_follow_the_app_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'LCMP.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.22.58'}))
            version = build_dmg.app_version(app)
            self.assertEqual(build_dmg.default_output(version), ROOT / 'build/dmg/LCMP-0.22.58.dmg')
            self.assertEqual(build_dmg.volume_name(version), 'LC Music Player 0.22.58')
            self.assertFalse(build_dmg.is_distribution(app))
            (app / 'Contents/Resources/CorrespondingSource').mkdir()
            self.assertTrue(build_dmg.is_distribution(app))

    def test_make_target_builds_the_dmg(self):
        makefile = (ROOT / 'Makefile').read_text()
        self.assertRegex(makefile, r'(?m)^dmg:\n\t\$\(PYTHON\) scripts/build-dmg\.py')


if __name__ == '__main__':
    unittest.main()
