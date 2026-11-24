"""Pinned tools, installed under .tools/ and never taken from PATH.

python3 scripts/toolchain.py setup          download and checksum every tool
python3 scripts/toolchain.py fe test .      run a pinned tool
"""

import hashlib
import io
import json
import platform
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / 'toolchain.lock.json').read_text())


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tool(name):
    spec = LOCK['tools'][name]
    path = ROOT / '.tools' / spec['path']
    if not path.is_file() or sha256(path) != spec['executable_sha256']:
        raise SystemExit(f'Missing or changed {name}; run make setup')
    return str(path)


def run(name, *args):
    print('+', name, *args, flush=True)
    subprocess.run([tool(name), *map(str, args)], cwd=ROOT, check=True)


def setup():
    host = f'{platform.system()}-{platform.machine()}'
    if host != LOCK['platform']:
        raise SystemExit(f'The toolchain lock supports {LOCK["platform"]}, not {host}')
    for name, spec in LOCK['tools'].items():
        path = ROOT / '.tools' / spec['path']
        if path.is_file() and sha256(path) == spec['executable_sha256']:
            continue
        print(f'Downloading {name} {spec["version"]}', flush=True)
        with urllib.request.urlopen(spec['url'], timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != spec['sha256']:
            raise SystemExit(f'Download checksum mismatch: {name}')
        if spec['archive_member']:
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                data = archive.extractfile(archive.getmember(spec['archive_member'])).read()
        if hashlib.sha256(data).hexdigest() != spec['executable_sha256']:
            raise SystemExit(f'Executable checksum mismatch: {name}')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755)
    for name, spec in LOCK.get('libraries', {}).items():
        archive_path = ROOT / '.tools' / f'{name}.tar.gz'
        if not archive_path.is_file() or sha256(archive_path) != spec['sha256']:
            print(f'Downloading {name} {spec["version"]}', flush=True)
            with urllib.request.urlopen(spec['url'], timeout=120) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != spec['sha256']:
                raise SystemExit(f'Download checksum mismatch: {name}')
            archive_path.write_bytes(data)
        # Extract only source files and licenses from the checksum-pinned archive.
        with tarfile.open(archive_path, mode='r:gz') as archive:
            for member in archive.getmembers():
                relative = Path(member.name).relative_to(spec['archive_root'])
                if not member.isfile() or not relative.parts or '..' in relative.parts:
                    continue
                if relative.parts[0] != 'src' and not relative.name.startswith('LICENSE'):
                    continue
                path = ROOT / '.tools' / name / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(archive.extractfile(member).read())
    print('Toolchain ready')


if __name__ == '__main__':
    if sys.argv[1:] == ['setup']:
        setup()
    elif len(sys.argv) > 1:
        raise SystemExit(subprocess.call([tool(sys.argv[1]), *sys.argv[2:]], cwd=ROOT))
    else:
        raise SystemExit(__doc__)
