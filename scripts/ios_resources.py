#!/usr/bin/env python3
"""Xcode build phase of the iPhone app: bundle LCMP's license and stamp the Git-derived version.

Usage (from the build phase): ios_resources.py <app bundle directory>
       ios_resources.py --version-only <extension bundle directory>
The widget extension carries the same version as the app it is embedded in, but no license files.
"""
import json
import plistlib
import sys
from pathlib import Path

from acknowledgements import generate
from app_version import resolve as resolve_version
from project_license import bundle

ROOT = Path(__file__).resolve().parent.parent


def main():
    version_only = sys.argv[1] == '--version-only'
    app = Path(sys.argv[-1])
    if not version_only:
        bundle_licenses(app)
    version = stamp_version(app)
    print(json.dumps({'version': version, 'bundle': str(app)}))


def bundle_licenses(app):
    bundle(ROOT, app / 'LCMPLicense')
    # The package has no third-party dependency; an empty graph writes an empty index.
    # Adding one requires the resolved graph here, as scripts/build-app.py does for macOS.
    if (ROOT / 'Package.resolved').exists():
        raise RuntimeError('Third-party dependencies need their notices in the iPhone app; extend ios_resources.py')
    generate(ROOT / 'Package.resolved', {'dependencies': []}, ROOT / '.build/artifacts', app / 'ThirdPartyLicenses')


def stamp_version(app):
    version = resolve_version(ROOT)
    info_path = app / 'Info.plist'
    with info_path.open('rb') as file:
        info = plistlib.load(file)
    info['CFBundleShortVersionString'] = version
    info['CFBundleVersion'] = version
    with info_path.open('wb') as file:
        plistlib.dump(info, file, fmt=plistlib.FMT_BINARY)
    return version


if __name__ == '__main__':
    main()
