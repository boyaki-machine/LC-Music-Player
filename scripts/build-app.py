#!/usr/bin/env python3
"""Build a local macOS .app with dynamically linked audio frameworks and notices."""
import argparse
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
    args = parser.parse_args()
    command = [str(ROOT / "scripts/swift.sh"), "build", "-c", args.configuration]
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
    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", commands):
        if rpath.startswith(str(ROOT / ".build")):
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(binary)], check=True)
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(binary)], check=True)
    for framework in sorted(products.glob("*.framework")):
        destination = contents / "Frameworks" / framework.name
        shutil.copytree(framework, destination, symlinks=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True)

    # Preserve exact notices from the pinned dependency checkouts.
    notices = contents / "Resources/ThirdPartyLicenses"
    for checkout in sorted((ROOT / ".build/checkouts").iterdir()):
        for item in checkout.rglob("*"):
            if ".git" in item.relative_to(checkout).parts:
                continue
            if item.is_file() and (item.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT"))
                                   or item.name == "ACKNOWLEDGMENTS.md"):
                target = notices / checkout.name / item.relative_to(checkout).parent
                target.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target / item.name)
    shutil.copy2(ROOT / "Package.resolved", notices / "Package.resolved")
    shutil.copy2(ROOT / "docs/design/11_third-party-dependencies.md", notices / "dependency-notes.md")
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleExecutable": "LCMP", "CFBundleIdentifier": "local.lcmp.player",
            "CFBundleName": "LCMP", "CFBundleDisplayName": "LC Music Player",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.2",
            "CFBundleVersion": "2", "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
        }, file)
    # Ad-hoc signing uses no private signing key and does not read Keychain.
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
