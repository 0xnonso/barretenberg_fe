"""Run every check: Fe unit and compile-fail tests, generator checks, native
proof verification, then the Forge differential tests against Solidity."""

import copy
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import build
import check_reference
from generate import circuit_module, generate_from_circuit, load_key, parse_key, render
from toolchain import ROOT, run, tool
from version import check_release, provenance, source_revision


def version_metadata():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        manifest = root / 'fe.toml'
        manifest.write_text('[ingot]\nname = "fixture"\nversion = "0.1.0"\n')
        (root / 'CHANGELOG.md').write_text('## [0.1.0] - 2026-11-24\n')
        assert source_revision(root) == 'unknown'
        assert check_release('v0.1.0', root) == '0.1.0'
        try:
            check_release('v0.2.0', root)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted a release tag inconsistent with fe.toml')

        def git(*args):
            return subprocess.check_output(
                ['git', '-C', str(root), *args], stderr=subprocess.DEVNULL, text=True
            ).strip()

        git('init', '--quiet')
        git('add', 'fe.toml', 'CHANGELOG.md')
        git(
            '-c',
            'user.name=Test',
            '-c',
            'user.email=test@example.invalid',
            '-c',
            'core.hooksPath=/dev/null',
            'commit',
            '--no-gpg-sign',
            '--quiet',
            '-m',
            'fixture',
        )
        revision = git('rev-parse', 'HEAD')
        assert source_revision(root) == revision
        untracked = root / 'new.fe'
        untracked.write_text('// local source\n')
        assert source_revision(root) == revision + '-dirty'
        untracked.unlink()
        manifest.write_text(manifest.read_text() + '\n')
        assert source_revision(root) == revision + '-dirty'
        archive = root / 'archive'
        archive.mkdir()
        shutil.copy2(manifest, archive / 'fe.toml')
        assert source_revision(archive) == 'unknown', 'Archive inherited its parent repository revision'
        manifest.write_text('[ingot]\nversion = "0.2.0"\n')
        try:
            check_release(root=root)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted a release without changelog notes')
    print('version metadata checks passed')


def compile_fail():
    """Each tests/compile_fail/<case>.fe must be rejected with its `// expect:` message."""
    cases = sorted((ROOT / 'tests/compile_fail').glob('*.fe'))
    assert cases, 'No compile-fail cases found'
    with tempfile.TemporaryDirectory() as directory:
        ingot = Path(directory)
        shutil.copytree(ROOT / 'src', ingot / 'src', ignore=shutil.ignore_patterns('tests', 'lib.fe'))
        (ingot / 'fe.toml').write_text('[ingot]\nname = "compile_fail"\nversion = "0.1.0"\n')
        (ingot / 'src/lib.fe').write_text('')  # control: the copied modules alone must compile
        subprocess.run([tool('fe'), 'check', ingot], check=True, capture_output=True)
        for case in cases:
            source = case.read_text()
            header = source.splitlines()[0]
            assert header.startswith('// expect: '), f'{case.name}: missing expected diagnostic'
            expected = header.removeprefix('// expect: ').strip().lower()
            assert expected, f'{case.name}: empty expected diagnostic'
            (ingot / 'src/lib.fe').write_text(source)
            result = subprocess.run([tool('fe'), 'check', '--color', 'never', ingot], capture_output=True, text=True)
            if result.returncode == 0 or expected not in (result.stdout + result.stderr).lower():
                raise SystemExit(f'{case.name}: expected rejection with "{expected}"\n{result.stdout}{result.stderr}')
    print(f'{len(cases)} compile-fail cases rejected')


def entity_layout():
    """Entity indices must follow the pinned Solidity WIRE enum."""
    wire = (ROOT / 'reference/solidity/honk/HonkTypes.sol').read_text().split('enum WIRE {')[1].split('}')[0]
    names = [name.strip() for name in wire.split(',') if name.strip()]
    indices = dict(re.findall(r'pub const (\w+): usize = (\d+)', (ROOT / 'src/entities.fe').read_text()))
    assert len(names) == 41 and all(int(indices[name]) == i for i, name in enumerate(names))


def reference_oracle():
    assert check_reference.tokens('a++ + b') != check_reference.tokens('a + ++b')
    assert check_reference.tokens('a /* comment */ + b') == check_reference.tokens('a+b')
    sources = [
        (ROOT / name).read_text()
        for name in [
            'reference/solidity/honk/BaseZKHonkVerifier.sol',
            'reference/solidity/generated/ArithmeticVerifier.sol',
            'tests/solidity/helpers/OpeningReference.sol',
        ]
    ]
    check_reference.check_opening_adapter(*sources)
    for index in range(3):
        changed = sources.copy()
        old = 'mem.unshiftedScalarNeg * mem.batchingChallenge'
        assert old in changed[index]
        changed[index] = changed[index].replace(old, 'mem.unshiftedScalarNeg + mem.batchingChallenge', 1)
        try:
            check_reference.check_opening_adapter(*changed)
        except ValueError:
            continue
        raise AssertionError(f'Opening oracle drift went undetected in source {index}')
    check_reference.check_opening_adapter(*[source + '\n// Non-executable change\n' for source in sources])
    print('opening oracle drift checks passed')


def generator():
    for name in build.FIXTURES:
        artifacts = ROOT / 'fixtures' / name / 'artifacts'
        document = json.loads((artifacts / 'vk.json').read_text())
        parse_key(document)
        assert b''.join(int(w, 16).to_bytes(32, 'big') for w in document['vk']) == (artifacts / 'vk').read_bytes()
        assert bytes.fromhex(document['hash'][2:]) == (artifacts / 'vk_hash').read_bytes()
    key = json.loads((ROOT / 'fixtures/arithmetic/artifacts/vk.json').read_text())
    assert render(circuit_module(key)).startswith(f'// Generator: {provenance()}\n')
    for index, value in [(0, 1), (0, 26), (1, 7), (2, 4), (3, 1)]:
        bad = copy.deepcopy(key)
        bad['vk'][index] = f'0x{value:064x}'
        try:
            parse_key(bad)
        except ValueError:
            continue
        raise AssertionError(f'accepted invalid key word {index} = {value}')
    # Malformed encodings, including ones Python's int() would accept.
    for field, value in [
        ('hash', '-1'),
        ('hash', '0x-' + '0' * 63 + '1'),
        ('hash', None),
        ('hash', f'0x{21888242871839275222246405745257275088548364400416034343698204186575808495617:064x}'),
        ('vk', ['0x' + '0' * 62 + '_5'] + key['vk'][1:]),
        ('vk', [' 0x' + '0' * 63 + '5'] + key['vk'][1:]),
    ]:
        bad = copy.deepcopy(key)
        bad[field] = value
        try:
            parse_key(bad)
        except ValueError:
            continue
        raise AssertionError(f'accepted malformed {field}: {value!r}')
    for name in build.FIXTURES:
        artifacts = ROOT / 'fixtures' / name / 'artifacts'
        assert load_key(artifacts / 'vk') == load_key(artifacts / 'vk.json') | {
            'hash': load_key(artifacts / 'vk')['hash']
        }
        assert circuit_module(load_key(artifacts / 'vk')) == circuit_module(load_key(artifacts / 'vk.json'))
    other = json.loads((ROOT / 'fixtures/ecdsa_batch/artifacts/vk.json').read_text())

    def without_circuit(text):
        return re.sub(r'pub mod circuit \{.*?\n\}\n', '', text, flags=re.S)

    assert without_circuit(render(circuit_module(key))) == without_circuit(render(circuit_module(other)))
    print('generator checks passed')


if __name__ == '__main__':
    print(f'Release metadata valid: v{check_release()}')
    run('ruff', 'format', '--check', 'scripts')
    run('ruff', 'check', 'scripts')
    run('fe', 'fmt', '--check', 'src')
    run('fe', 'fmt', '--check', 'tests/probes/src')
    run('fe', 'fmt', '--check', 'tests/compile_fail')
    run('forge', 'fmt', '--check', 'tests/solidity')
    version_metadata()
    run('fe', 'test', '.')
    compile_fail()
    entity_layout()
    reference_oracle()
    generator()
    for name in build.FIXTURES:
        artifacts = f'fixtures/{name}/artifacts'
        run(
            'barretenberg',
            'verify',
            '-p',
            f'{artifacts}/proof',
            '-i',
            f'{artifacts}/public_inputs',
            '-k',
            f'{artifacts}/vk',
            '--verifier_target',
            'evm',
            '-c',
            '.tools/crs',
        )
    # End to end from a compiled circuit through the pinned bb write_vk.
    with tempfile.TemporaryDirectory() as directory:
        fixture = Path(directory) / 'arithmetic'
        fixture.mkdir()
        shutil.copy2(ROOT / 'fixtures/arithmetic/Nargo.toml', fixture / 'Nargo.toml')
        shutil.copytree(ROOT / 'fixtures/arithmetic/src', fixture / 'src')
        run('nargo', 'compile', '--program-dir', fixture)
        generate_from_circuit(fixture / 'target/arithmetic.json', Path(directory) / 'V.fe')
        assert (Path(directory) / 'V.fe').read_text() == render(
            circuit_module(load_key(ROOT / 'fixtures/arithmetic/artifacts/vk'))
        )
    build.probes()
    build.corpus()
    run('forge', 'test', '--offline', '--no-match-contract', 'BenchTest')
