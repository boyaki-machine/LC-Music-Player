"""App signatures: ad-hoc by default, Developer ID when the untracked signing settings name an identity."""
from dataclasses import dataclass
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
# Not tracked in Git, like iOS/Local.xcconfig: the identity names the developer and the team.
SETTINGS_FILE = ROOT / 'Signing.local.xcconfig'
IDENTITY_KEY = 'LCMP_SIGNING_IDENTITY'
NOTARY_PROFILE_KEY = 'LCMP_NOTARY_PROFILE'

# The hardened runtime makes dyld ignore DYLD_* injection, and library validation
# stays on: the app loads only system libraries.
# The sandbox reads only files the user picks; library bookmarks keep that access.
ENTITLEMENTS = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-write': True,
    'com.apple.security.files.bookmarks.app-scope': True,
}


@dataclass(frozen=True)
class Settings:
    """A Developer ID signing identity (its name or SHA-1) and the notarytool Keychain profile; None means ad-hoc."""
    identity: str | None = None
    notary_profile: str | None = None

    @property
    def developer_id(self):
        return self.identity is not None

    def describe(self):
        # The identity names a person and a team, so it is not printed.
        return f'Developer ID (from {SETTINGS_FILE.name} or the environment)' if self.developer_id else 'ad-hoc'


def parse_settings(text):
    """KEY = VALUE lines of the settings file; whole-line // comments and blank lines are skipped."""
    values = {}
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        match = re.fullmatch(r'([A-Z_][A-Z0-9_]*)\s*=\s*(.*)', line)
        if not match:
            raise ValueError(f'{SETTINGS_FILE.name}:{number}: expected KEY = VALUE')
        key, value = match.groups()
        if key not in (IDENTITY_KEY, NOTARY_PROFILE_KEY):
            raise ValueError(f'{SETTINGS_FILE.name}:{number}: unknown setting {key}')
        values[key] = value.strip().strip('"')
    return values


def read_settings(path=SETTINGS_FILE, environ=os.environ):
    """The settings file overridden by environment variables of the same names; empty values are unset."""
    values = parse_settings(path.read_text()) if path.is_file() else {}
    for key in (IDENTITY_KEY, NOTARY_PROFILE_KEY):
        if key in environ:
            values[key] = environ[key].strip()
    identity = values.get(IDENTITY_KEY) or None
    profile = values.get(NOTARY_PROFILE_KEY) or None
    if profile and not identity:
        raise ValueError(f'{NOTARY_PROFILE_KEY} needs {IDENTITY_KEY}: only Developer ID signatures can be notarized')
    return Settings(identity, profile)


def codesign_command(path, settings, timestamp=False, entitlements=None):
    """The codesign call for one bundle. Only Developer ID signatures take a secure timestamp, which notarization needs;
    other builds skip it so they do not contact Apple."""
    command = ['codesign', '--force', '--sign', settings.identity or '-']
    if settings.developer_id:
        command.append('--timestamp' if timestamp else '--timestamp=none')
    if entitlements is not None:
        command += ['--options', 'runtime', '--entitlements', str(entitlements)]
    return command + [str(path)]


def requirement(settings):
    """A code requirement that only a signature by the configured Developer ID identity satisfies."""
    identity = settings.identity
    if re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
        leaf = f'certificate leaf = H"{identity.upper()}"'
    else:
        leaf = f'certificate leaf[subject.CN] = "{identity}"'
    # The Developer ID intermediate certificate carries this marker.
    return f'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and {leaf}'


def sign_app(app, bundles=(), settings=None, timestamp=False):
    """Sign the nested bundles, then the app that seals them, and verify it."""
    settings = settings or Settings()
    for bundle in bundles:
        subprocess.run(codesign_command(bundle, settings, timestamp), check=True)
    with tempfile.TemporaryDirectory(prefix='lcmp-sign-') as temporary:
        entitlements = Path(temporary) / 'LCMP.entitlements'
        entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
        subprocess.run(codesign_command(app, settings, timestamp, entitlements), check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    if settings.developer_id:
        check_signer(app, settings)


def check_signer(path, settings):
    """Fail unless the code is signed by the configured Developer ID identity."""
    result = subprocess.run(['codesign', '--verify', '--strict', f'-R={requirement(settings)}', str(path)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f'{path.name} is not signed by the Developer ID identity of {SETTINGS_FILE.name}')
