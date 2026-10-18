"""Ad-hoc app signature for every app build."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

# The hardened runtime makes dyld ignore DYLD_* injection, and library validation
# stays on: the app loads only system libraries.
# The sandbox reads only files the user picks; library bookmarks keep that access.
ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-write': True,
    'com.apple.security.files.bookmarks.app-scope': True,
}

def sign_app(app):
    """Sign the bundle, then verify it."""
    with tempfile.TemporaryDirectory(prefix='lcmp-sign-') as temporary:
        entitlements = Path(temporary) / 'LCMP.entitlements'
        entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                        '--entitlements', str(entitlements), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
