#!/usr/bin/env python3
"""Build a local macOS .app with dynamically linked audio frameworks and notices."""
import argparse
import json
from acknowledgements import generate
from app_version import resolve as resolve_version
from project_license import bundle, documents
from signing import sign_app
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--output", type=Path, default=ROOT / "build/LCMP.app",
                        help="Output .app path; use a different path while the current app is running")
    parser.add_argument("--frameworks-dir", type=Path,
                        help="Source-built framework overrides (distribution builder)")
    parser.add_argument("--prefix-map", action="store_true",
                        help="Remove this checkout's path from compiled file/debug locations")
    args = parser.parse_args()
    documents(ROOT)
    command = [str(ROOT / "scripts/swift.sh"), "build", "-c", args.configuration]
    if args.prefix_map:
        for flag in ['-Xcc', '-Xcxx']:
            command += [flag, f'-ffile-prefix-map={ROOT}=.', flag, f'-fdebug-prefix-map={ROOT}=.']
        for flag in ['-file-prefix-map', '-debug-prefix-map']:
            command += ['-Xswiftc', flag, '-Xswiftc', f'{ROOT}=.']
    subprocess.run(command, check=True, cwd=ROOT)
    products = Path(subprocess.check_output(command + ["--show-bin-path"], text=True, cwd=ROOT).strip())
    app = args.output.resolve()
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for directory in ["MacOS", "Frameworks", "Resources/ThirdPartyLicenses"]:
        (contents / directory).mkdir(parents=True)
    binary = contents / "MacOS/LCMP"
    shutil.copy2(products / "LCMP", binary)
    if args.prefix_map:
        subprocess.run(["strip", "-S", str(binary)], check=True)
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", commands):
        if rpath.startswith(str(ROOT / ".build")):
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(binary)], check=True)
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(binary)], check=True)
    for framework in sorted(products.glob("*.framework")):
        destination = contents / "Frameworks" / framework.name
        override = args.frameworks_dir / framework.name if args.frameworks_dir else None
        shutil.copytree(override if override and override.exists() else framework,
                        destination, symlinks=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True)

    # Regenerate from the currently resolved graph, not every cached checkout.
    graph = json.loads(subprocess.check_output(
        [str(ROOT / "scripts/swift.sh"), "package", "show-dependencies", "--format", "json"],
        text=True, cwd=ROOT))
    notices = contents / "Resources/ThirdPartyLicenses"
    generate(ROOT / "Package.resolved", graph, ROOT / ".build/artifacts", notices,
             ROOT / "third-party/notices.json")
    shutil.copy2(ROOT / "Package.resolved", notices / "Package.resolved")
    shutil.copy2(ROOT / "docs/design/11_third-party-dependencies.md", notices / "dependency-notes.md")
    bundle(ROOT, contents / "Resources/LCMPLicense")
    # Rendered by scripts/render-app-icon.swift; committed so builds do not redraw it.
    shutil.copy2(ROOT / "assets/AppIcon.icns", contents / "Resources/AppIcon.icns")
    # One dotted version; the build number is its last part, not a separate value.
    version = resolve_version(ROOT)
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleExecutable": "LCMP", "CFBundleIdentifier": "local.lcmp.player",
            "CFBundleName": "LCMP", "CFBundleDisplayName": "LC Music Player",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
            "CFBundleVersion": version, "LSMinimumSystemVersion": "14.0",
            "CFBundleIconFile": "AppIcon", "NSHighResolutionCapable": True,
        }, file)
    # Ad-hoc signing uses no private signing key and does not read Keychain.
    sign_app(app)
    print(app)


if __name__ == "__main__":
    main()
