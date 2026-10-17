"""App version <major>.<minor>.<build>, derived from the develop history.

- major: set by the developer below.
- minor: merges into develop (first-parent merge commits) since the current major began.
- build: commits reachable from the built revision, which is develop's commit count on develop.
"""
import os
import re
import subprocess
import sys

MAJOR = 0
# The commit where the current major version began; its merges are not counted.
# None counts from the start of the history. Set both values together when raising MAJOR.
MAJOR_START = None


def _count(root, *arguments):
    output = subprocess.check_output(['git', '-C', str(root), 'rev-list', '--count', *arguments],
                                     text=True, stderr=subprocess.DEVNULL)
    return int(output.strip())


def version(root, revision='HEAD', major=None, major_start=None):
    major = MAJOR if major is None else major
    major_start = MAJOR_START if major is None else major_start
    since = f'{major_start}..{revision}' if major_start else revision
    minor = _count(root, '--merges', '--first-parent', since)
    build = _count(root, revision)
    return f'{major}.{minor}.{build}'


def resolve(root):
    """LCMP_VERSION overrides; a tree without Git history (the source snapshot) falls back to <major>.0.0."""
    override = os.environ.get('LCMP_VERSION')
    if override:
        if not re.fullmatch(r'\d+\.\d+\.\d+', override):
            raise ValueError('LCMP_VERSION must be <major>.<minor>.<build>')
        return override
    try:
        return version(root)
    except (OSError, subprocess.CalledProcessError):
        fallback = f'{MAJOR}.0.0'
        print(f'warning: no Git history; app version is {fallback} (set LCMP_VERSION to override)', file=sys.stderr)
        return fallback
