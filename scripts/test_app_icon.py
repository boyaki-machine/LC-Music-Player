from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / 'assets/AppIcon.icns'
IOS_ICON = ROOT / 'iOS/LCMPiOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
PNG = b'\x89PNG\r\n\x1a\n'
# icns element types that iconutil writes as PNG, with their pixel sizes.
PNG_ELEMENTS = {b'ic07': 128, b'ic08': 256, b'ic09': 512, b'ic10': 1024,
                b'ic11': 32, b'ic12': 64, b'ic13': 256, b'ic14': 512}


def elements(data):
    if data[:4] != b'icns' or struct.unpack('>I', data[4:8])[0] != len(data):
        raise ValueError('not an icns file')
    offset, found = 8, {}
    while offset < len(data):
        kind, length = data[offset:offset + 4], struct.unpack('>I', data[offset + 4:offset + 8])[0]
        if length < 8 or offset + length > len(data):
            raise ValueError(f'broken element {kind!r}')
        found[kind] = data[offset + 8:offset + length]
        offset += length
    return found


class AppIconTests(unittest.TestCase):
    def test_icon_has_every_size_from_16_to_1024(self):
        found = elements(ICON.read_bytes())
        for kind, size in PNG_ELEMENTS.items():
            with self.subTest(kind=kind):
                body = found[kind]
                self.assertEqual(body[:8], PNG)
                self.assertEqual(struct.unpack('>II', body[16:24]), (size, size))
        # 16 and 32 points at 1x are stored as ARGB, not PNG.
        self.assertIn(b'ic04', found)
        self.assertIn(b'ic05', found)

    def test_broken_icns_is_rejected(self):
        data = ICON.read_bytes()
        with self.assertRaises(ValueError): elements(data[:-1])
        with self.assertRaises(ValueError): elements(b'icnx' + data[4:])

    def test_app_bundle_uses_the_icon(self):
        build = (ROOT / 'scripts/build-app.py').read_text()
        self.assertIn('"assets/AppIcon.icns", contents / "Resources/AppIcon.icns"', build)
        self.assertIn('"CFBundleIconFile": "AppIcon"', build)

    def test_iphone_icon_is_an_opaque_1024_square(self):
        data = IOS_ICON.read_bytes()
        self.assertEqual(data[:8], PNG)
        width, height, depth, color_type = struct.unpack('>IIBB', data[16:26])
        self.assertEqual((width, height), (1024, 1024))
        # Colour type 2 is RGB without alpha; iOS rejects icons with transparency.
        self.assertEqual((depth, color_type), (8, 2))
        contents = (IOS_ICON.parent / 'Contents.json').read_text()
        self.assertIn('"filename" : "AppIcon.png"', contents)
        self.assertIn('"size" : "1024x1024"', contents)


if __name__ == '__main__':
    unittest.main()
