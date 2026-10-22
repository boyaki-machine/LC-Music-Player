#!/usr/bin/env python3
"""Build the drag-to-install DMG for macOS from a release app built for distribution."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BACKGROUND = ROOT / 'assets/DMGBackground.tiff'
# Finder layout in points. The background (scripts/render-dmg-background.swift) is drawn for the same values.
WINDOW = (640, 400)
WINDOW_ORIGIN = (200, 120)
ICON_SIZE = 128
TEXT_SIZE = 13
APP_POSITION = (170, 176)
APPLICATIONS_POSITION = (470, 176)
APP_NAME = 'LCMP.app'
# Height of the Finder title bar measured on the current macOS, which the bounds include; the bars below it are hidden.
TITLE_BAR = 32
# Finder sometimes ignores the bounds it is given and keeps its default window, so the layout is checked and redone.
LAYOUT_ATTEMPTS = 3


def app_version(app):
    with open(app / 'Contents/Info.plist', 'rb') as file:
        return plistlib.load(file)['CFBundleShortVersionString']


def default_output(version):
    return ROOT / f'build/dmg/LCMP-{version}.dmg'


def volume_name(version):
    return f'LC Music Player {version}'


def window_bounds():
    """Finder bounds of the window: left, top, right, bottom including the title bar."""
    left, top = WINDOW_ORIGIN
    return left, top, left + WINDOW[0], top + WINDOW[1] + TITLE_BAR


def applescript(volume):
    """Finder settings for the window; Finder stores them in the volume's .DS_Store."""
    left, top, right, bottom = window_bounds()
    bounds = f'{{{left}, {top}, {right}, {bottom}}}'
    # Set the bounds until Finder reports them back, and check them again just before the closing that saves them.
    return f'''
tell application "Finder"
  tell disk "{volume}"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    repeat 10 times
      set bounds of container window to {bounds}
      delay 0.5
      if bounds of container window is {bounds} then exit repeat
    end repeat
    set options to icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to {ICON_SIZE}
    set text size of options to {TEXT_SIZE}
    set label position of options to bottom
    set shows item info of options to false
    set shows icon preview of options to false
    set background picture of options to file ".background:background.tiff"
    set extension hidden of item "{APP_NAME}" to true
    set position of item "{APP_NAME}" of container window to {{{APP_POSITION[0]}, {APP_POSITION[1]}}}
    set position of item "Applications" of container window to {{{APPLICATIONS_POSITION[0]}, {APPLICATIONS_POSITION[1]}}}
    close
    open
    update without registering applications
    delay 1
    if bounds of container window is not {bounds} then
      set bounds of container window to {bounds}
      delay 1
    end if
    if bounds of container window is not {bounds} then error "Finder did not take the window bounds"
    close
  end tell
end tell
'''


def read_ds_store(data):
    """Records of a Finder .DS_Store as {(file name, code): value}; blobs are bytes and other types are kept raw."""
    def block(address):
        offset = (address & ~0x1f) + 4
        return data[offset:offset + (1 << (address & 0x1f))]

    if data[:8] != b'\x00\x00\x00\x01Bud1':
        raise ValueError('Not a .DS_Store file')
    root_offset, root_size = struct.unpack_from('>II', data, 8)
    root = data[root_offset + 4:root_offset + 4 + root_size]
    count = struct.unpack_from('>I', root)[0]
    addresses = struct.unpack_from(f'>{count}I', root, 8)
    position = 8 + 4 * ((count + 255) // 256 * 256)
    directory = {}
    for _ in range(struct.unpack_from('>I', root, position)[0]):
        length = root[position + 4]
        name = root[position + 5:position + 5 + length]
        directory[name] = struct.unpack_from('>I', root, position + 5 + length)[0]
        position += 5 + length
    tree_root = struct.unpack_from('>I', block(addresses[directory[b'DSDB']]))[0]

    sizes = {b'long': 4, b'shor': 4, b'type': 4, b'bool': 1, b'comp': 8, b'dutc': 8}
    records = {}

    def node(number):
        content = block(addresses[number])
        last, count = struct.unpack_from('>II', content)
        position = 8
        for _ in range(count):
            if last:
                node(struct.unpack_from('>I', content, position)[0])
                position += 4
            length = struct.unpack_from('>I', content, position)[0]
            name = content[position + 4:position + 4 + 2 * length].decode('utf-16-be')
            position += 4 + 2 * length
            code, kind = content[position:position + 4].decode('ascii'), content[position + 4:position + 8]
            position += 8
            if kind == b'blob':
                size = struct.unpack_from('>I', content, position)[0]
                value, position = content[position + 4:position + 4 + size], position + 4 + size
            elif kind == b'ustr':
                size = struct.unpack_from('>I', content, position)[0]
                value = content[position + 4:position + 4 + 2 * size].decode('utf-16-be')
                position += 4 + 2 * size
            else:
                value, position = content[position:position + sizes[kind]], position + sizes[kind]
            records[name, code] = value
        if last:
            node(last)

    node(tree_root)
    return records


def layout_problems(ds_store):
    """Differences between the layout Finder saved and the one the background is drawn for; empty when it matches."""
    try:
        records = read_ds_store(ds_store.read_bytes())
    except (OSError, ValueError, KeyError, IndexError, struct.error) as error:
        return [f'Cannot read {ds_store.name}: {error}']
    problems = []
    left, top, right, bottom = window_bounds()
    try:
        saved = plistlib.loads(records['.', 'bwsp'])['WindowBounds']
        size = tuple(int(float(value)) for value in saved.replace('{', '').replace('}', '').split(',')[2:])
    except (KeyError, ValueError, plistlib.InvalidFileException):
        saved, size = None, None
    if size != (right - left, bottom - top):
        problems.append(f'Window bounds {saved}, expected the size {{{right - left}, {bottom - top}}}')
    try:
        options = plistlib.loads(records['.', 'icvp'])
    except (KeyError, plistlib.InvalidFileException):
        options = {}
    if options.get('iconSize') != ICON_SIZE or options.get('backgroundType') != 2:
        problems.append(f'Icon view options: icon size {options.get("iconSize")}, background type {options.get("backgroundType")}')
    for name, expected in [(APP_NAME, APP_POSITION), ('Applications', APPLICATIONS_POSITION)]:
        location = records.get((name, 'Iloc'))
        position = struct.unpack_from('>II', location) if location and len(location) >= 8 else None
        if position != expected:
            problems.append(f'{name} at {position}, expected {expected}')
    return problems


def directory_size(path):
    total = 0
    for directory, _, files in os.walk(path):
        for name in files:
            file = Path(directory) / name
            if not file.is_symlink():
                total += file.stat().st_size
    return total


def attach(image, *options):
    result = plistlib.loads(subprocess.check_output(
        ['hdiutil', 'attach', '-plist', '-noautoopen', '-noverify', *options, str(image)]))
    points = [entity['mount-point'] for entity in result['system-entities'] if 'mount-point' in entity]
    if len(points) != 1:
        raise RuntimeError(f'Unexpected mount points for {image}: {points}')
    return Path(points[0])


def detach(mount_point):
    for _ in range(5):
        if subprocess.run(['hdiutil', 'detach', str(mount_point)], stdout=subprocess.DEVNULL).returncode == 0:
            return
        subprocess.run(['sleep', '1'])
    subprocess.run(['hdiutil', 'detach', '-force', str(mount_point)], check=True)


def lay_out(volume, ds_store):
    """Have Finder lay out the window and wait until the saved layout matches, redoing it a few times."""
    problems = []
    for _ in range(LAYOUT_ATTEMPTS):
        result = subprocess.run(['osascript', '-'], input=applescript(volume), text=True)
        # Finder writes the .DS_Store after the window closes.
        for _ in range(20):
            problems = layout_problems(ds_store) if ds_store.exists() else ['Finder did not save the window layout (.DS_Store)']
            if not problems:
                return
            subprocess.run(['sleep', '0.5'])
        if result.returncode != 0:
            problems.append('The Finder script failed')
        print(f'Redoing the Finder layout: {"; ".join(problems)}', file=sys.stderr)
    raise RuntimeError(f'Finder did not save the window layout: {"; ".join(problems)}')


def build(app, output, work):
    version = app_version(app)
    volume = volume_name(version)
    if Path('/Volumes', volume).exists():
        raise RuntimeError(f'Eject the mounted volume "{volume}" first; Finder addresses the disk by name')
    staging = work / 'staging'
    staging.mkdir()
    subprocess.run(['ditto', str(app), str(staging / APP_NAME)], check=True)
    (staging / 'Applications').symlink_to('/Applications')
    (staging / '.background').mkdir()
    shutil.copy2(BACKGROUND, staging / '.background/background.tiff')

    writable = work / 'writable.dmg'
    megabytes = directory_size(staging) * 12 // 10 // 2**20 + 16
    subprocess.run(['hdiutil', 'create', '-quiet', '-srcfolder', str(staging), '-volname', volume, '-fs', 'HFS+',
                    '-format', 'UDRW', '-size', f'{megabytes}m', str(writable)], check=True)
    mount_point = attach(writable, '-readwrite')
    try:
        if mount_point != Path('/Volumes', volume):
            raise RuntimeError(f'The volume was mounted at {mount_point}; eject other "{volume}" volumes')
        lay_out(volume, mount_point / '.DS_Store')
        shutil.rmtree(mount_point / '.fseventsd', ignore_errors=True)
        subprocess.run(['sync'], check=True)
    finally:
        detach(mount_point)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = work / output.name
    subprocess.run(['hdiutil', 'convert', '-quiet', str(writable), '-format', 'UDZO',
                    '-imagekey', 'zlib-level=9', '-o', str(temporary)], check=True)
    verify(temporary)
    shutil.move(str(temporary), output)
    return output


def verify(image):
    """Check the compressed image: checksum, the signed app, the Applications link and the saved window layout."""
    subprocess.run(['hdiutil', 'verify', '-quiet', str(image)], check=True)
    with tempfile.TemporaryDirectory(prefix='lcmp-dmg-verify-') as temporary:
        mount_point = attach(image, '-readonly', '-nobrowse', '-mountpoint', temporary)
        try:
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mount_point / APP_NAME)], check=True)
            if os.readlink(mount_point / 'Applications') != '/Applications':
                raise RuntimeError('Applications must link to /Applications')
            for name in ['.background/background.tiff', '.DS_Store']:
                if not (mount_point / name).is_file():
                    raise RuntimeError(f'Missing {name} in the image')
            problems = layout_problems(mount_point / '.DS_Store')
            if problems:
                raise RuntimeError(f'Wrong window layout: {"; ".join(problems)}')
            visible = sorted(entry.name for entry in mount_point.iterdir() if not entry.name.startswith('.'))
            if visible != ['Applications', APP_NAME]:
                raise RuntimeError(f'Unexpected visible items: {visible}')
        finally:
            detach(mount_point)


def release_app(work):
    """Build the release app without this checkout's path in the executable."""
    app = work / 'release' / APP_NAME
    subprocess.run([sys.executable, str(ROOT / 'scripts/build-app.py'), '--configuration', 'release',
                    '--prefix-map', '--output', str(app)], check=True)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='DMG path (default: build/dmg/LCMP-<version>.dmg)')
    parser.add_argument('--app', type=Path, help='Package an existing app instead of building one')
    parser.add_argument('--verify', type=Path, help='Verify an existing DMG only')
    args = parser.parse_args()
    if args.verify:
        verify(args.verify.resolve())
        print(f'Verified {args.verify}')
        return
    (ROOT / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.lcmp-dmg-', dir=ROOT / 'build') as temporary:
        work = Path(temporary)
        app = args.app.resolve(strict=True) if args.app else release_app(work)
        output = (args.output or default_output(app_version(app))).resolve()
        print(build(app, output, work))


if __name__ == '__main__':
    main()
