#!/usr/bin/env python3
"""The oldest Python the macOS build and test scripts support. macOS's own /usr/bin/python3 (3.9) is past
its end of life and too old. Kept to Python 3.9 syntax so that an old Python reaches the message."""
import platform
import sys

MINIMUM = (3, 12)


def require(version=None):
    """Exits with a message naming the Python in use when it is older than MINIMUM."""
    if tuple(version or sys.version_info[:2]) < MINIMUM:
        found = '.'.join(map(str, version)) if version else platform.python_version()
        sys.exit(f'Python {MINIMUM[0]}.{MINIMUM[1]} or later is required, but {sys.executable} is {found}. '
                 'Install a current Python (Homebrew or python.org), or pass PYTHON=<path> to make.')


if __name__ == '__main__':
    require()
