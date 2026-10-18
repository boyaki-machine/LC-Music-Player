#!/usr/bin/env python3
"""Build the drag-to-install DMG for macOS from the source distribution app."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
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


def app_version(app):
    with open(app / 'Contents/Info.plist', 'rb') as file:
        return plistlib.load(file)['CFBundleShortVersionString']


def default_output(version):
    return ROOT / f'build/dmg/LCMP-{version}.dmg'


def volume_name(version):
    return f'LC Music Player {version}'


def is_distribution(app):
    return (app / 'Contents/Resources/CorrespondingSource').is_dir()


def applescript(volume):
    """Finder settings for the window; Finder stores them in the volume's .DS_Store."""
    left, top = WINDOW_ORIGIN
    right, bottom = left + WINDOW[0], top + WINDOW[1] + TITLE_BAR
    return f'''
tell application "Finder"
  tell disk "{volume}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {{{left}, {top}, {right}, {bottom}}}
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
    close
  end tell
end tell
'''


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
        subprocess.run(['osascript', '-'], input=applescript(volume), text=True, check=True)
        # Wait until Finder has written the layout before ejecting.
        for _ in range(20):
            if (mount_point / '.DS_Store').exists():
                break
            subprocess.run(['sleep', '0.5'])
        else:
            raise RuntimeError('Finder did not save the window layout (.DS_Store)')
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
    """Check the compressed image: checksum, the signed app, the Applications link and the layout files."""
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
            visible = sorted(entry.name for entry in mount_point.iterdir() if not entry.name.startswith('.'))
            if visible != ['Applications', APP_NAME]:
                raise RuntimeError(f'Unexpected visible items: {visible}')
        finally:
            detach(mount_point)


def distribution_app(work, audio_source):
    """Build the source distribution and return its app, which carries the corresponding source."""
    output = work / 'distribution'
    command = [sys.executable, str(ROOT / 'scripts/distribution.py'), '--output', str(output)]
    if audio_source:
        command += ['--audio-source', str(audio_source)]
    subprocess.run(command, check=True)
    return output / 'LCMP-distribution/LCMP.app'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='DMG path (default: build/dmg/LCMP-<version>.dmg)')
    parser.add_argument('--app', type=Path,
                        help='Package an existing app instead of building the source distribution')
    parser.add_argument('--audio-source', type=Path, help='Passed to distribution.py')
    parser.add_argument('--verify', type=Path, help='Verify an existing DMG only')
    args = parser.parse_args()
    if args.verify:
        verify(args.verify.resolve())
        print(f'Verified {args.verify}')
        return
    if args.app and args.audio_source:
        parser.error('--audio-source applies only when the distribution is built')
    (ROOT / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.lcmp-dmg-', dir=ROOT / 'build') as temporary:
        work = Path(temporary)
        app = args.app.resolve(strict=True) if args.app else distribution_app(work, args.audio_source)
        if not is_distribution(app):
            print('warning: the app has no CorrespondingSource; this DMG is for local checks, not for distribution',
                  file=sys.stderr)
        output = (args.output or default_output(app_version(app))).resolve()
        print(build(app, output, work))


if __name__ == '__main__':
    main()
