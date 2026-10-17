"""Validate and bundle LCMP's own license, independently of OSS notices."""
import hashlib

# Unmodified https://www.apache.org/licenses/LICENSE-2.0.txt
APACHE_2_SHA256 = 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'


def documents(root):
    result = {name: (root / name).read_bytes() for name in ('LICENSE', 'NOTICE')}
    for data in result.values():
        if not data.decode('utf-8').strip():
            raise ValueError('Empty LCMP license document')
    if hashlib.sha256(result['LICENSE']).hexdigest() != APACHE_2_SHA256:
        raise ValueError('LCMP LICENSE differs from the official Apache 2.0 text')
    return result


def bundle(root, destination):
    originals = documents(root)
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in originals.items():
        (destination / name).write_bytes(data)
