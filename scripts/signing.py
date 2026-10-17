"""Ad-hoc app signature shared by local builds, distributions and the relink kit."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

# The hardened runtime makes dyld ignore DYLD_* injection. Library validation stays
# off: ad-hoc frameworks have no Team ID, and the LGPL relink path replaces them.
# The sandbox reads only files the user picks; library bookmarks keep that access.
ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-write': True,
    'com.apple.security.files.bookmarks.app-scope': True,
    'com.apple.security.cs.disable-library-validation': True,
}

def sign_app(app):
    """Sign the bundle after its frameworks, then verify the whole bundle."""
    with tempfile.TemporaryDirectory(prefix='lcmp-sign-') as temporary:
        entitlements = Path(temporary) / 'LCMP.entitlements'
        entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
        subprocess.run(['codesign', '--force', '--sign', '-', '--options', 'runtime',
                        '--entitlements', str(entitlements), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
