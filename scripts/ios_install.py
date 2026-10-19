#!/usr/bin/env python3
"""Find the connected iPhone, and install and launch the built app on it (used by `make ios-device`).

Usage: ios_install.py udid [device name or identifier]
       ios_install.py install <LCMP.app> [device name or identifier]
`udid` prints the device's UDID for the xcodebuild destination. Without a device, the only paired
iPhone is used; with several, name one with IOS_DEVICE.
"""
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


def devices():
    with tempfile.TemporaryDirectory() as folder:
        output = Path(folder) / 'devices.json'
        subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(output)],
                       check=True, stdout=subprocess.DEVNULL)
        found = json.loads(output.read_text()).get('result', {}).get('devices', [])
    # The list also contains simulators; only physical iPhones can take a signed device build.
    return [d for d in found if d.get('hardwareProperties', {}).get('platform') == 'iOS'
            and d.get('hardwareProperties', {}).get('reality', 'physical') == 'physical']


def choose(wanted):
    candidates = devices()
    if wanted:
        candidates = [d for d in candidates
                      if wanted in (d.get('identifier'), d.get('hardwareProperties', {}).get('udid'),
                                    d.get('deviceProperties', {}).get('name'))]
    else:
        paired = [d for d in candidates if d.get('connectionProperties', {}).get('pairingState') == 'paired']
        candidates = paired or candidates
    if len(candidates) != 1:
        names = ', '.join(d.get('deviceProperties', {}).get('name', '?') for d in devices()) or 'none'
        raise SystemExit(f'Choose one iPhone with IOS_DEVICE=<name>. Found: {names}')
    return candidates[0]


def main():
    arguments = sys.argv[1:]
    if arguments[:1] == ['udid'] and len(arguments) in (1, 2):
        device = choose(arguments[1] if len(arguments) == 2 and arguments[1] else None)
        print(device['hardwareProperties']['udid'])
    elif arguments[:1] == ['install'] and len(arguments) in (2, 3):
        app = Path(arguments[1])
        with (app / 'Info.plist').open('rb') as file:
            bundle_id = plistlib.load(file)['CFBundleIdentifier']
        device = choose(arguments[2] if len(arguments) == 3 and arguments[2] else None)['identifier']
        subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app)], check=True)
        subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, bundle_id], check=True)
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
