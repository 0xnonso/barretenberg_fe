"""Read the project version and check release metadata without changing Git state."""

import argparse
import re
import subprocess
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def project_version(root=ROOT):
    version = tomllib.loads((root / 'fe.toml').read_text())['ingot']['version']
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('fe.toml must declare a release version in MAJOR.MINOR.PATCH format')
    return version


def source_revision(root=ROOT):
    """Identify a checkout, marking local edits; archives have no Git revision."""

    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True).strip()

    try:
        # A source archive inside another checkout must not inherit that checkout's identity.
        if Path(git('rev-parse', '--show-toplevel')).resolve() != root.resolve():
            return 'unknown'
        revision = git('rev-parse', '--verify', 'HEAD')
        dirty = bool(git('status', '--porcelain', '--untracked-files=normal'))
    except (OSError, subprocess.CalledProcessError):
        return 'unknown'
    return revision + ('-dirty' if dirty else '')


def provenance(root=ROOT):
    return f'barretenberg_fe {project_version(root)} (revision {source_revision(root)})'


def check_release(tag=None, root=ROOT):
    version = project_version(root)
    if not re.search(
        rf'^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$', (root / 'CHANGELOG.md').read_text(), re.M
    ):
        raise ValueError(f'CHANGELOG.md needs a dated entry for {version}')
    if tag is not None and tag != f'v{version}':
        raise ValueError(f'Tag {tag!r} does not match fe.toml version v{version}')
    return version


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='check the version and dated changelog entry')
    parser.add_argument('--tag', help='also check that a proposed release tag matches the version')
    args = parser.parse_args()
    try:
        if args.check or args.tag:
            print(f'Release metadata valid: v{check_release(args.tag)}')
        else:
            print(provenance())
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(f'error: {error}') from None
