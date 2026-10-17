#!/usr/bin/env python3
"""Build the LGPL codecs and their framework dependencies from supplied source."""
import argparse
from pathlib import Path
import shutil
import shlex
import subprocess

CODECS = ('lame', 'mpc', 'mpg123', 'sndfile', 'tta-cpp')
BUILT_FRAMEWORKS = ('FLAC', 'lame', 'mpc', 'mpg123', 'ogg', 'opus', 'sndfile', 'tta-cpp', 'vorbis')


def rebuild(source, output, arch):
    source = source.resolve(strict=True)
    output.mkdir(parents=True, exist_ok=False)
    frameworks = output / 'Frameworks'
    frameworks.mkdir()
    for name in CODECS:
        derived = output / name
        command = ['xcodebuild', '-project', str(source / name / (name + '.xcodeproj')),
                   '-scheme', name, '-configuration', 'Release', '-sdk', 'macosx',
                   '-derivedDataPath', str(derived.resolve()), 'CODE_SIGNING_ALLOWED=NO',
                   'MACOSX_DEPLOYMENT_TARGET=14.0', f'ARCHS={arch}', 'ONLY_ACTIVE_ARCH=YES']
        mapping = shlex.join([f'-ffile-prefix-map={source}=AudioXCFrameworks',
                              f'-fdebug-prefix-map={source}=AudioXCFrameworks'])
        command += [f'OTHER_CFLAGS=$(inherited) {mapping}',
                    f'OTHER_CPLUSPLUSFLAGS=$(inherited) {mapping}', 'build']
        with (output / (name + '.log')).open('w') as log:
            try:
                subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
            except subprocess.CalledProcessError as error:
                log.flush()
                detail = (output / (name + '.log')).read_text()[-6000:]
                raise RuntimeError(f'{name} source build failed:\n{detail}') from error
        for framework in (derived / 'Build/Products/Release').glob('*.framework'):
            target = frameworks / framework.name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(framework, target, symlinks=True)
            # Keep code/relocations; omit build-machine debug paths.
            subprocess.run(['strip', '-S', str(target / target.stem)], check=True)
    if {p.stem for p in frameworks.glob('*.framework')} != set(BUILT_FRAMEWORKS):
        raise ValueError('Source build produced an unexpected framework set')
    return frameworks


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New build directory')
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], required=True)
    args = parser.parse_args()
    print(rebuild(args.source, args.output, args.arch))
