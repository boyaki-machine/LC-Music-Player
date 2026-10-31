import importlib.util
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_dmg', ROOT / 'scripts/build-dmg.py')
build_dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_dmg)


def ds_store(records):
    """A .DS_Store with one leaf node, laid out as Finder writes it; records are (file name, code, type, value)."""
    def record(name, code, kind, value):
        encoded = name.encode('utf-16-be')
        data = struct.pack('>I', len(name)) + encoded + code.encode() + kind.encode()
        if kind == 'blob':
            return data + struct.pack('>I', len(value)) + value
        return data + value

    leaf = struct.pack('>II', 0, len(records)) + b''.join(record(*item) for item in sorted(records))
    tree = struct.pack('>IIIII', 2, 0, len(records), 1, 0x1000)
    blocks = [None, tree, leaf]
    body, addresses = bytearray(), [0]
    offset = 0x20
    for content in blocks[1:]:
        size = 0x20
        while size < len(content):
            size *= 2
        addresses.append(offset | size.bit_length() - 1)
        body += content.ljust(size, b'\0')
        offset += size
    root = struct.pack('>II', len(addresses), 0) + struct.pack(f'>{len(addresses)}I', *addresses)
    root = root.ljust(8 + 4 * 256, b'\0') + struct.pack('>I', 1) + bytes([4]) + b'DSDB' + struct.pack('>I', 1)
    root += struct.pack('>I', 0) * 32
    header = b'\x00\x00\x00\x01Bud1' + struct.pack('>III', offset, len(root), offset) + b'\0' * 16
    return (header + bytes(body)).ljust(offset + 4, b'\0') + root


def layout(window=None, app=None, applications=None, icon_size=None):
    """Records of the layout build-dmg.py asks for, with the given values changed."""
    left, top, right, bottom = build_dmg.window_bounds()
    width, height = window or (right - left, bottom - top)
    bwsp = plistlib.dumps({'WindowBounds': f'{{{{{left}, {top}}}, {{{width}, {height}}}}}', 'ShowToolbar': False})
    icvp = plistlib.dumps({'iconSize': float(icon_size or build_dmg.ICON_SIZE), 'backgroundType': 2})
    location = lambda point: struct.pack('>II', *point) + bytes.fromhex('ffffffffffff0000')
    return [('.', 'bwsp', 'blob', bwsp), ('.', 'icvp', 'blob', icvp),
            ('.', 'vSrn', 'long', struct.pack('>I', 1)),
            ('Applications', 'Iloc', 'blob', location(applications or build_dmg.APPLICATIONS_POSITION)),
            (build_dmg.APP_NAME, 'Iloc', 'blob', location(app or build_dmg.APP_POSITION))]


class BuildDMGTests(unittest.TestCase):
    def layout_problems(self, records):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / '.DS_Store'
            path.write_bytes(ds_store(records))
            return build_dmg.layout_problems(path)

    def test_reads_the_records_of_a_ds_store(self):
        records = build_dmg.read_ds_store(ds_store(layout()))
        self.assertEqual(records['.', 'vSrn'], struct.pack('>I', 1))
        self.assertEqual(struct.unpack_from('>II', records['Applications', 'Iloc']), build_dmg.APPLICATIONS_POSITION)
        self.assertIn('WindowBounds', plistlib.loads(records['.', 'bwsp']))

    def test_accepts_the_layout_the_background_is_drawn_for(self):
        self.assertEqual(self.layout_problems(layout()), [])

    def test_rejects_the_default_finder_window(self):
        # Finder kept its default window instead of the bounds it was given (LCMP-1.14.104.dmg).
        problems = self.layout_problems(layout(window=(920, 436)))
        self.assertEqual(len(problems), 1)
        self.assertIn('{920, 436}', problems[0])

    def test_rejects_moved_icons_and_other_icon_sizes(self):
        self.assertEqual(len(self.layout_problems(layout(app=(100, 176), applications=(470, 200)))), 2)
        self.assertEqual(len(self.layout_problems(layout(icon_size=64))), 1)

    def test_rejects_a_missing_or_broken_layout(self):
        self.assertEqual(len(self.layout_problems([r for r in layout() if r[1] != 'bwsp'])), 1)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / '.DS_Store'
            path.write_bytes(b'not a ds store')
            self.assertEqual(len(build_dmg.layout_problems(path)), 1)

    def test_layout_is_redone_until_finder_saves_it(self):
        script = build_dmg.applescript('LC Music Player 0.1.2')
        bounds = '{%d, %d, %d, %d}' % build_dmg.window_bounds()
        self.assertIn(f'if bounds of container window is {bounds} then exit repeat', script)
        self.assertIn(f'if bounds of container window is not {bounds} then error', script)
        self.assertGreater(build_dmg.LAYOUT_ATTEMPTS, 1)

    def test_backgrounds_have_standard_and_retina_images(self):
        for background in build_dmg.BACKGROUNDS.values():
            info = subprocess.check_output(['tiffutil', '-info', str(background)], text=True)
            sizes = [tuple(map(int, size)) for size in re.findall(r'Image Width: (\d+) Image Length: (\d+)', info)]
            width, height = build_dmg.WINDOW
            self.assertEqual(sizes, [(width, height), (width * 2, height * 2)])
            self.assertEqual(re.findall(r'Resolution: (\d+), \d+', info), ['72', '144'])

    def test_only_the_ad_hoc_background_explains_the_way_past_gatekeeper(self):
        self.assertEqual(build_dmg.background(False).name, 'DMGBackground.tiff')
        self.assertEqual(build_dmg.background(True).name, 'DMGBackground-Notarized.tiff')
        self.assertNotEqual(build_dmg.background(False).read_bytes(), build_dmg.background(True).read_bytes())
        source = (ROOT / 'scripts/render-dmg-background.swift').read_text()
        self.assertIn('let note = notarized ? notarizedNote : adHocNote', source)
        self.assertIn('「このまま開く」', source.split('let adHocNote = ')[1].split('\n')[0])
        self.assertNotIn('このまま開く', source.split('let notarizedNote = ')[1].split('\n')[0])

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
        self.assertEqual(build_dmg.window_bounds(), (left, top, right, bottom))
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

    def test_signature_of_a_distribution(self):
        app = ('Executable=/Volumes/x/LCMP.app/Contents/MacOS/LCMP\n'
               'CodeDirectory v=20500 size=12532 flags=0x10000(runtime) hashes=380+7 location=embedded\n'
               'Authority=Developer ID Application: Example (ABCDE12345)\nAuthority=Developer ID Certification Authority\n'
               'Authority=Apple Root CA\nTimestamp=26 Oct 2026 at 0:51:30\n')
        self.assertEqual(build_dmg.signature_problems(app, runtime=True), [])
        self.assertEqual(build_dmg.signature_problems(app.replace('flags=0x10000(runtime)', 'flags=0x0(none)'), runtime=True),
                         ['no hardened runtime'])
        self.assertEqual(build_dmg.signature_problems(app.replace('Timestamp=', 'Signed Time=')), ['no secure timestamp'])
        ad_hoc = 'CodeDirectory v=20500 size=12530 flags=0x10002(adhoc,runtime) hashes=381+7\nSignature=adhoc\n'
        self.assertEqual(build_dmg.signature_problems(ad_hoc, runtime=True),
                         ['not signed with a Developer ID Application certificate', 'no secure timestamp'])
        development = app.replace('Developer ID Application:', 'Apple Development:')
        self.assertEqual(build_dmg.signature_problems(development),
                         ['not signed with a Developer ID Application certificate'])

    def notarize(self, stdout, stderr=''):
        calls = []

        def run(command, **options):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout if 'submit' in command else '', stderr)

        build_dmg.notarize(Path('LCMP.dmg'), 'LCMP-notary', run)
        return calls

    def test_notarization_waits_for_the_result_and_staples_the_ticket(self):
        calls = self.notarize('{"id": "e894", "status": "Accepted", "message": "Processing complete"}')
        self.assertEqual(calls, [
            ['xcrun', 'notarytool', 'submit', 'LCMP.dmg', '--keychain-profile', 'LCMP-notary',
             '--wait', '--output-format', 'json'],
            ['xcrun', 'stapler', 'staple', 'LCMP.dmg']])

    def test_a_rejected_submission_fails_with_the_way_to_its_log(self):
        with self.assertRaises(RuntimeError) as raised:
            self.notarize('{"id": "e894", "status": "Invalid", "message": "Processing complete"}')
        self.assertIn('status: Invalid', str(raised.exception))
        self.assertIn('xcrun notarytool log e894 --keychain-profile LCMP-notary', str(raised.exception))
        # No answer at all (no network, wrong profile): point to the history and keep notarytool's message.
        with self.assertRaises(RuntimeError) as raised:
            self.notarize('', 'Error: No Keychain password item found for profile: LCMP-notary')
        self.assertIn('status: unknown', str(raised.exception))
        self.assertIn('No Keychain password item found', str(raised.exception))
        self.assertIn('xcrun notarytool history --keychain-profile LCMP-notary', str(raised.exception))

    def test_make_target_builds_the_dmg(self):
        makefile = (ROOT / 'Makefile').read_text()
        self.assertRegex(makefile, r'(?m)^dmg: python-check\n\t\$\(PYTHON\) scripts/build-dmg\.py')


if __name__ == '__main__':
    unittest.main()
