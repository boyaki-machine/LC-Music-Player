#!/usr/bin/env python3
"""Create a local distribution draft with exact sources and an offline relink kit."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile

from acknowledgements import notice_files
from rebuild_frameworks import rebuild
from project_license import documents
from signing import sign_app

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOTS = {'Sources', 'Tests', 'scripts', 'docs', 'third-party', 'prototypes'}
SOURCE_FILES = {'Package.swift', 'Package.resolved', 'Makefile', 'README.md', 'AGENTS.md',
                '.gitignore', 'LICENSE', 'NOTICE'}


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')


def inventory(root, exclude=()):
    result = {}
    root = root.resolve(strict=True)
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix()
        if relative in exclude:
            continue
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(root):
                raise ValueError('Artifact symlink escapes distribution')
            result[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            result[relative] = {'sha256': digest(path)}
    return result


def verify(root):
    expected = json.loads((root / 'SHA256SUMS.json').read_text())
    if inventory(root, ['SHA256SUMS.json']) != expected:
        raise ValueError('Distribution files, hashes or symlinks differ')
    return len(expected)


def git_files(source):
    return subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z']).decode().split('\0')[:-1]


def copy_files(source, paths, destination):
    source = source.resolve(strict=True)
    for name in paths:
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or '.git' in relative.parts:
            raise ValueError('Invalid source path')
        original = source / relative
        if original.is_symlink() or not original.resolve(strict=True).is_relative_to(source):
            raise ValueError('Source snapshot contains a symlink')
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
        target.chmod(0o755 if os.access(original, os.X_OK) else 0o644)


def clean_revision(source, revision):
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all'], text=True)
    if actual != revision or dirty:
        raise ValueError('Dependency revision or tracked source differs')


def project_files():
    names = subprocess.check_output(
        ['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')[:-1]
    return sorted(name for name in names if Path(name).parts[0] in SOURCE_ROOTS or name in SOURCE_FILES)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/distribution', help='New output directory')
    parser.add_argument('--audio-source', type=Path, help='Clean checkout of the pinned AudioXCFrameworks revision')
    parser.add_argument('--verify', type=Path, help='Verify an extracted distribution directory only')
    args = parser.parse_args()
    if args.verify:
        print(f'Verified {verify(args.verify)} files/symlinks')
        return
    output = args.output.resolve()
    if output.exists():
        raise ValueError('Use a new output directory; existing artifacts are preserved')
    config = json.loads((ROOT / 'third-party/distribution.json').read_text())
    if config['schemaVersion'] != 1 or digest(ROOT / 'Package.resolved') != config['resolvedSHA256']:
        raise ValueError('Review source provenance after changing Package.resolved')
    documents(ROOT)
    arch = platform.machine()
    if arch not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported native architecture')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.lcmp-distribution-', dir=output.parent) as temporary:
        work = Path(temporary)
        payload = work / 'LCMP-distribution'
        payload.mkdir()
        staged_sources = work / 'CorrespondingSource'
        staged_sources.mkdir()
        project = staged_sources / 'LCMP'
        files = project_files()
        copy_files(ROOT, files, project)
        project_hashes = inventory(project)
        audio = args.audio_source
        if audio is None:
            audio = work / 'upstream'
            subprocess.run(['git', '-c', 'credential.helper=', 'clone', '--no-checkout',
                            config['audioSourceURL'], str(audio)], check=True,
                           env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
            subprocess.run(['git', '-C', str(audio), 'checkout', '--detach', config['audioSourceRevision']], check=True)
        audio = audio.resolve(strict=True)
        clean_revision(audio, config['audioSourceRevision'])
        copy_files(audio, git_files(audio), staged_sources / 'AudioXCFrameworks')
        frameworks = rebuild(staged_sources / 'AudioXCFrameworks', work / 'codec-build', arch)
        app = payload / 'LCMP.app'
        subprocess.run([sys.executable, str(ROOT / 'scripts/build-app.py'), '--configuration', 'release',
                        '--prefix-map', '--frameworks-dir', str(frameworks), '--output', str(app)], check=True)
        # The application was compiled from the same source bytes we are supplying.
        if project_files() != files or any(digest(ROOT / name) != value['sha256'] for name, value in project_hashes.items()):
            raise ValueError('Project changed while building; retry with a stable worktree')
        graph = json.loads(subprocess.check_output(
            [str(ROOT / 'scripts/swift.sh'), 'package', 'show-dependencies', '--format', 'json'], text=True))
        nodes = {}

        def walk(node):
            for child in node.get('dependencies', []):
                if child['identity'] not in nodes:
                    nodes[child['identity']] = child
                    walk(child)
        walk(graph)
        pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
        if set(nodes) != {p['identity'] for p in pins}:
            raise ValueError('Resolved source graph differs')
        for pin in pins:
            checkout = Path(nodes[pin['identity']]['path'])
            clean_revision(checkout, pin['state']['revision'])
            copy_files(checkout, git_files(checkout), staged_sources / 'packages' / pin['identity'])
        # Include source-tree notices that binary wrapper packages do not carry.
        notices = app / 'Contents/Resources/ThirdPartyLicenses'
        catalogue = json.loads((notices / 'index.json').read_text())
        for package in catalogue['packages']:
            name = package['id'].removesuffix('-binary-xcframework')
            if name not in config['codecFrameworks']:
                continue
            for relative, original in notice_files(staged_sources / 'AudioXCFrameworks' / name):
                target = Path(package['id']) / 'rebuilt-source' / relative
                (notices / target).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, notices / target)
                package['documents'].append({'title': f'rebuilt-source/{relative.as_posix()}', 'path': target.as_posix()})
        write_json(notices / 'index.json', catalogue)
        link_list = ROOT / f'.build/out/Intermediates.noindex/LCMP.build/Release/LCMP-p.build/Objects-normal/{arch}/LCMP.LinkFileList'
        objects = [Path(name) for name in shlex.split(link_list.read_text())]
        names = [p.name for p in objects]
        if len(set(names)) != len(names) or 'taglib.o' not in names or 'LCMPApp.o' not in names:
            raise ValueError('Unrecognized Swift build system object list')
        object_dir = staged_sources / 'Objects'
        object_dir.mkdir()
        for original in objects:
            target = object_dir / original.name
            shutil.copyfile(original, target)
            subprocess.run(['strip', '-S', str(target)], check=True)
            if str(ROOT).encode() in target.read_bytes():
                raise ValueError(f'Build-machine path remains in {target.name}')
        shutil.copyfile(ROOT / 'scripts/relink.py', staged_sources / 'relink.py')
        shutil.copyfile(ROOT / 'scripts/signing.py', staged_sources / 'signing.py')
        shutil.copyfile(ROOT / 'third-party/RELINKING.txt', staged_sources / 'RELINKING.txt')
        shutil.copyfile(ROOT / 'third-party/CORRESPONDING-SOURCE.md', staged_sources / 'README.md')
        framework_hashes = {p.stem: digest(p / p.stem) for p in (app / 'Contents/Frameworks').glob('*.framework')}
        if set(framework_hashes) != set(config['frameworks']):
            raise ValueError('Bundled framework set differs from source correspondence')
        info = {'schemaVersion': 1, 'architecture': arch, 'deploymentTarget': config['deploymentTarget'],
                'objects': names, 'frameworks': config['frameworks'], 'frameworkSHA256': framework_hashes,
                'audioSourceURL': config['audioSourceURL'], 'audioSourceRevision': config['audioSourceRevision'],
                'resolvedSHA256': config['resolvedSHA256'], 'projectLicense': 'Apache-2.0',
                'projectLicenseSHA256': digest(project / 'LICENSE'),
                'projectNoticeSHA256': digest(project / 'NOTICE'),
                'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
                'codecBuild': 'LCMP/scripts/rebuild_frameworks.py (Release, native arch, macOS14, prefix maps)',
                'appBuild': 'LCMP/scripts/build-app.py --configuration release --prefix-map --frameworks-dir <source-built frameworks>'}
        write_json(staged_sources / 'build-info.json', info)
        write_json(staged_sources / 'SOURCE-SHA256SUMS.json', inventory(staged_sources))
        source_destination = app / 'Contents/Resources/CorrespondingSource'
        shutil.move(str(staged_sources), source_destination)
        sign_app(app)
        for binary in [app / 'Contents/MacOS/LCMP',
                       *[p / p.stem for p in (app / 'Contents/Frameworks').glob('*.framework')]]:
            if str(ROOT).encode() in binary.read_bytes():
                raise ValueError('Build-machine path remains in bundled Mach-O')
        write_json(payload / 'SHA256SUMS.json', inventory(payload))
        verify(payload)
        archive = work / 'LCMP-distribution.zip'
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(archive)], check=True)
        completed = work / 'completed'
        completed.mkdir()
        shutil.move(str(payload), completed / payload.name)
        shutil.move(str(archive), completed / archive.name)
        if output.exists():
            raise ValueError('Output appeared while building; preserving it')
        shutil.move(str(completed), output)
    print(output / 'LCMP-distribution.zip')
    print('LCMP: Apache-2.0; third-party licenses retained. Developer ID signing/notarization are not performed.')


if __name__ == '__main__':
    main()
