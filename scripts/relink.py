#!/usr/bin/env python3
"""Relink LCMP using its bundled application objects and a modified TagLib."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from signing import sign_app


def relink(source, output, taglib=None, rebuild_taglib=False, frameworks=None):
    source = source.resolve(strict=True)
    info = json.loads((source / 'build-info.json').read_text())
    app = source.parents[2]
    if app.suffix != '.app' or output.exists() or output.is_symlink():
        raise ValueError('Run the bundled script; output must be a new .app path')
    if output.suffix != '.app':
        raise ValueError('Output must have .app extension')
    with tempfile.TemporaryDirectory(prefix='lcmp-relink-') as temporary:
        work = Path(temporary)
        if rebuild_taglib:
            package = source / 'packages/cxxtaglib'
            command = ['swift', 'build', '--disable-keychain', '--disable-netrc',
                       '--package-path', str(package), '--scratch-path', str(work / 'taglib'),
                       '-c', 'release', '-Xcxx', f'-ffile-prefix-map={source}=CorrespondingSource']
            subprocess.run(command, check=True)
            products = Path(subprocess.check_output(command + ['--show-bin-path'], text=True).strip())
            taglib = products / 'taglib.o'
            if not taglib.is_file():
                raise ValueError('This Swift build system did not emit taglib.o')
        if taglib and not taglib.is_file():
            raise ValueError('Missing replacement TagLib object')
        shutil.copytree(app, output, symlinks=True)
        if frameworks:
            for framework in sorted(frameworks.glob('*.framework')):
                destination = output / 'Contents/Frameworks' / framework.name
                if not destination.is_dir():
                    raise ValueError('Unknown replacement framework')
                shutil.rmtree(destination)
                shutil.copytree(framework, destination, symlinks=True)
        for framework in (output / 'Contents/Frameworks').glob('*.framework'):
            subprocess.run(['codesign', '--force', '--sign', '-', str(framework)], check=True)
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        command = ['xcrun', 'swiftc', '-sdk', sdk, '-target',
                   f"{info['architecture']}-apple-macosx14.0", '-o',
                   str(output / 'Contents/MacOS/LCMP'), '-F', str(output / 'Contents/Frameworks'),
                   '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                   '-lc++', '-lz', '-lsqlite3']
        for name in info['frameworks']:
            command += ['-framework', name]
        for name in info['objects']:
            command.append(str(taglib if name == 'taglib.o' and taglib else source / 'Objects' / name))
        subprocess.run(command, check=True)
        subprocess.run(['strip', '-S', str(output / 'Contents/MacOS/LCMP')], check=True)
        sign_app(output)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New .app path')
    parser.add_argument('--taglib-object', type=Path)
    parser.add_argument('--rebuild-taglib', action='store_true')
    parser.add_argument('--frameworks', type=Path, help='Directory containing replacement .frameworks')
    args = parser.parse_args()
    if args.taglib_object and args.rebuild_taglib:
        parser.error('Choose an existing object or rebuild, not both')
    print(relink(Path(__file__).resolve().parent, args.output.absolute(),
                 args.taglib_object, args.rebuild_taglib, args.frameworks))
