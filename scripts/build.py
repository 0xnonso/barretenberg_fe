"""Build test artifacts: probe contracts and, per fixture, the Fe and Solidity verifiers.

out/probes/<Contract>.creation.bin
out/corpus/<fixture>/{
                      UltraHonkVerifier.fe, fe.bin, fe.runtime.bin, fe-relations.runtime.bin,
                      solidity.bin, RelationsLib.bin, ZKTranscriptLib.bin
                      }
"""

import shutil
import sys
from pathlib import Path

import check_reference
from generate import EIP170_LIMIT, IMMUTABLE_BYTES, generate
from toolchain import LOCK, ROOT, run

FIXTURES = sorted(p.name for p in (ROOT / 'fixtures').iterdir() if (p / 'artifacts/vk.json').exists())
LIBRARIES = {
    'RelationsLib': '0x0000000000000000000000000000000000001001',
    'ZKTranscriptLib': '0x0000000000000000000000000000000000001002',
}


def unhex(path):
    """Compilers emit hex text; Forge tests read raw bytes."""
    return bytes.fromhex(Path(path).read_text().strip().removeprefix('0x'))


def probes():
    check_reference.check()
    out = ROOT / 'out/probes'
    shutil.rmtree(out, ignore_errors=True)
    run('fe', 'build', 'tests/probes', '--emit', 'bytecode', '--out-dir', out)
    for path in out.glob('*.bin'):
        if not path.name.endswith('.creation.bin'):
            path.with_suffix('.creation.bin').write_bytes(unhex(path))


def fixture(name):
    artifacts, out = ROOT / 'fixtures' / name / 'artifacts', ROOT / 'out/corpus' / name
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    generate(artifacts / 'vk.json', out / 'UltraHonkVerifier.fe')
    run(
        'fe',
        'build',
        '--standalone',
        out / 'UltraHonkVerifier.fe',
        '-O',
        '2',
        '--emit',
        'bytecode,runtime-bytecode',
        '--out-dir',
        out / 'fe',
    )
    (out / 'fe.bin').write_bytes(unhex(out / 'fe/UltraHonkVerifier.bin'))
    (out / 'fe.runtime.bin').write_bytes(unhex(out / 'fe/UltraHonkVerifier.runtime.bin'))
    (out / 'fe-relations.runtime.bin').write_bytes(unhex(out / 'fe/RelationsLib.runtime.bin'))
    reference = (out / 'Reference.sol').relative_to(ROOT)
    run('barretenberg', 'write_solidity_verifier', '-k', artifacts / 'vk', '-o', reference, '--verifier_target', 'evm')
    run(
        'solc',
        '--bin',
        '--optimize',
        '--optimize-runs',
        '1',
        '--evm-version',
        LOCK['evm_version'],
        '--metadata-hash',
        'none',
        '--libraries',
        ','.join(f'{reference}:{lib}={address}' for lib, address in LIBRARIES.items()),
        '-o',
        out / 'solidity',
        reference,
    )
    (out / 'solidity.bin').write_bytes(unhex(out / 'solidity/HonkVerifier.bin'))
    for lib in LIBRARIES:
        (out / f'{lib}.bin').write_bytes(unhex(out / f'solidity/{lib}.bin'))
    return (out / 'fe.runtime.bin').read_bytes(), (out / 'fe-relations.runtime.bin').read_bytes()


def corpus(names=FIXTURES):
    runtimes = {name: fixture(name) for name in names}
    verifier, relations = next(iter(runtimes.values()))
    # The key is constructor data, so every circuit must compile to the same code.
    assert all(r == (verifier, relations) for r in runtimes.values()), 'Fe runtime depends on the circuit'
    assert max(len(verifier) + IMMUTABLE_BYTES, len(relations)) <= EIP170_LIMIT, 'EIP-170 limit exceeded'
    print(
        f'{len(runtimes)} verifiers: one {len(verifier)}-byte runtime ({len(verifier) + IMMUTABLE_BYTES} deployed), '
        f'RelationsLib {len(relations)} bytes'
    )


if __name__ == '__main__':
    probes()
    corpus(sys.argv[1:] or FIXTURES)
