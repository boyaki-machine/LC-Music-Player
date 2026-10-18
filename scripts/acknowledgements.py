"""Generate an offline catalogue from the resolved dependency graph and notices."""
import json
import hashlib
from pathlib import Path
import re
import shutil


def notice_files(root):
    root = root.resolve(strict=True)
    result = []
    for item in sorted(root.rglob('*')):
        relative = item.relative_to(root)
        if '.git' in relative.parts:
            continue
        if item.name.upper().startswith(('LICENSE', 'COPYING', 'COPYRIGHT', 'ACKNOWLEDGMENT', 'ACKNOWLEDGEMENT', 'NOTICE')):
            if not item.resolve(strict=True).is_relative_to(root):
                raise ValueError('Notice escapes source directory')
            if item.is_file():
                # A plain-text viewer must be able to display every indexed document.
                item.read_text(encoding='utf-8')
                result.append((relative, item))
    return result


def generate(resolved, graph, artifacts, destination, supplements=None):
    # SwiftPM writes no Package.resolved while the package has no dependencies.
    pins = json.loads(resolved.read_text())['pins'] if resolved.exists() else []
    nodes = {}

    def walk(node):
        for dep in node.get('dependencies', []):
            identity = dep['identity']
            if identity in nodes:
                if nodes[identity] != dep:
                    raise ValueError('Conflicting dependency graph')
                continue
            nodes[identity] = dep
            walk(dep)
    walk(graph)
    if set(nodes) != {p['identity'] for p in pins}:
        raise ValueError('Resolved dependencies and graph differ')
    entries = []
    copies = []
    additions = json.loads(supplements.read_text()) if supplements else {}
    for pin in sorted(pins, key=lambda p: p['identity']):
        identity = pin['identity']
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]*', identity):
            raise ValueError('Invalid package identity')
        node = nodes[identity]
        url = pin['location']
        if not url.startswith('https://') or '@' in url or '?' in url or '#' in url:
            raise ValueError('Expected public HTTPS repository URL')
        if node['url'].removesuffix('.git') != url.removesuffix('.git'):
            raise ValueError('Repository mismatch')
        version = pin['state'].get('version')
        if version and node['version'] != version:
            raise ValueError('Dependency version mismatch')
        documents = []
        sources = [('source', Path(node['path']))]
        if artifacts and (artifacts / identity).exists():
            sources.append(('artifacts', artifacts / identity))
        for category, source in sources:
            for relative, item in notice_files(source):
                path = (Path(identity) / category / relative).as_posix()
                documents.append({'title': f'{category}/{relative.as_posix()}', 'path': path})
                copies.append((item, path))
        if identity in additions:
            extra = additions[identity]
            if extra['revision'] != pin['state']['revision']:
                raise ValueError(f'Supplement revision mismatch: {identity}')
            base = supplements.parent.resolve(strict=True)
            for document in extra['documents']:
                relative = Path(document['path'])
                if relative.is_absolute() or any(p in ('..', '.') for p in relative.parts):
                    raise ValueError('Invalid supplement path')
                item = (base / relative).resolve(strict=True)
                if not item.is_relative_to(base):
                    raise ValueError('Supplement escapes source directory')
                item.read_text(encoding='utf-8')
                if hashlib.sha256(item.read_bytes()).hexdigest() != document['sha256']:
                    raise ValueError('Supplement hash mismatch')
                path = (Path(identity) / 'supplement' / relative).as_posix()
                documents.append({'title': f'supplement/{relative.as_posix()}', 'path': path})
                copies.append((item, path))
        if not documents:
            raise ValueError(f'No notices for resolved package {identity}')
        entries.append({'id': identity, 'name': node['name'], 'version': version,
                        'revision': pin['state']['revision'], 'url': url, 'documents': documents})
    # Validate everything before replacing the catalogue; stale entries cannot survive.
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for source, path in copies:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    (destination / 'index.json').write_text(json.dumps({'schemaVersion': 1, 'packages': entries},
                                                    ensure_ascii=False, indent=2, sort_keys=True) + '\n')
