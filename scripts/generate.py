"""Generate a standalone Fe UltraHonk verifier.

    python3 scripts/generate.py -b target/circuit.json -o UltraHonkVerifier.fe   # runs pinned bb write_vk
    python3 scripts/generate.py -k out/vk -o UltraHonkVerifier.fe                # bb's binary key (+ vk_hash)
    python3 scripts/generate.py -k out/vk.json -o UltraHonkVerifier.fe           # bb's JSON key export

Like `bb write_solidity_verifier`, the shared verifier source (src/) is fixed
and only the key is filled in: templates/circuit.fe.in becomes the `circuit`
module, which the contract constructor stores as immutable data. Keys come from
bb 6.0.0 `write_vk --verifier_target evm`; a binary key is used with the
`vk_hash` file bb writes beside it.
"""

import argparse
import json
import re
import tempfile
from pathlib import Path

from version import provenance

ROOT = Path(__file__).resolve().parents[1]
R = 21888242871839275222246405745257275088548364400416034343698204186575808495617
Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583
MAX_LOG_N = 25  # src/verification_key.fe (Solidity CONST_PROOF_SIZE_LOG_N)
# Immutable data appended to the runtime: VerificationKey (59 words) + RelationsLib address.
IMMUTABLE_BYTES = 60 * 32
EIP170_LIMIT = 24576
# HonkTypes.WIRE order of the 28 commitments.
LABELS = [
    's1', 's2', 's3', 's4', 'id1', 'id2', 'id3', 'id4', 'lagrange_first', 'lagrange_last',
    'q_lookup', 't1', 't2', 't3', 't4', 'qm', 'qr', 'qo', 'qc', 'ql', 'q4', 'q_arith', 'q_range',
    'q_elliptic', 'q_memory', 'q_nnf', 'q_poseidon_external', 'q_poseidon_internal',
]  # fmt: skip


def word(value):
    """A canonical 32-byte word: exactly 0x plus 64 hex digits (int() alone
    would also accept signs, underscores and whitespace)."""
    if not isinstance(value, str) or not re.fullmatch(r'0x[0-9a-fA-F]{64}', value):
        raise ValueError(f'Expected a 0x-prefixed 32-byte hex word, got {value!r}')
    return int(value, 16)


def parse_key(document):
    """Validate the canonical key: 3 metadata words, then 28 BN254 points."""
    if document.get('bb_version') != '6.0.0' or document.get('scheme') != 'ultra_honk':
        raise ValueError('Only bb 6.0.0 UltraHonk ZK/Keccak keys are supported')
    words = document.get('vk', [])
    if not isinstance(words, list) or len(words) != 59:
        raise ValueError('Expected 59 canonical 32-byte words')
    log_n, inputs, offset, *coordinates = map(word, words)
    if not 2 <= log_n <= MAX_LOG_N or not 8 <= inputs < 1 << log_n or offset != 5:
        raise ValueError('Unsupported circuit dimensions or public-input offset')
    vk_hash = word(document.get('hash'))
    if vk_hash >= R:
        raise ValueError('VK hash is not a scalar field element')
    points = list(zip(coordinates[::2], coordinates[1::2], strict=True))
    for x, y in points:
        if x >= Q or y >= Q or ((x, y) != (0, 0) and (y * y - x * x * x - 3) % Q):
            raise ValueError('VK commitment is not a canonical BN254 point')
    return log_n, inputs, vk_hash, points


def circuit_module(document):
    log_n, inputs, vk_hash, points = parse_key(document)
    commitments = ''.join(
        f'            // {label}\n'
        f'            EncodedG1 {{ x: coordinate_constant(0x{x:064x}), y: coordinate_constant(0x{y:064x}) }},\n'
        for label, (x, y) in zip(LABELS, points, strict=True)
    )
    source = (ROOT / 'templates/circuit.fe.in').read_text()
    for name, value in (
        ('N', str(1 << log_n)),
        ('LOG_N', str(log_n)),
        ('TOTAL_INPUTS', str(inputs)),
        ('VK_HASH', f'{vk_hash:064x}'),
        ('COMMITMENTS', commitments),
    ):
        source = source.replace(f'@{name}@', value)
    return source


def render(circuit):
    """Inline every src/ module (tests excluded) into one file; `circuit` is replaced."""
    sources = {
        path.relative_to(ROOT / 'src').with_suffix('').parts: path.read_text()
        for path in sorted((ROOT / 'src').rglob('*.fe'))
        if 'tests' not in path.parts
    }
    sources[('circuit',)] = circuit

    def module(path):
        children = sorted({p[len(path)] for p in sources if len(p) > len(path) and p[: len(path)] == path})
        body = sources.get(path, '').rstrip() + '\n' + ''.join('\n' + module((*path, c)) for c in children)
        indented = ''.join('    ' + line if line.strip() else line for line in body.splitlines(True))
        return f'pub mod {path[-1]} {{\n{indented}}}\n'

    header = (
        f'// Generator: {provenance()}\n'
        '// Generated for Barretenberg 6.0.0 UltraHonk ZK/Keccak. Do not edit.\n'
        '// Compile with: fe build --standalone <file.fe> -O 2\n\n'
    )
    return (
        header
        + sources.pop(('lib',)).rstrip()
        + '\n'
        + ''.join('\n' + module((name,)) for name in sorted({p[0] for p in sources}))
    )


def load_key(path):
    """bb's JSON export, or its binary key (59 big-endian words) plus `vk_hash`."""
    path = Path(path)
    if path.suffix == '.json':
        return json.loads(path.read_text())
    words, digest = path.read_bytes(), (path.parent / 'vk_hash').read_bytes()
    if len(words) != 59 * 32 or len(digest) != 32:
        raise ValueError(f'Expected a 1888-byte binary key and 32-byte vk_hash beside it: {path}')
    return {
        'bb_version': '6.0.0',
        'scheme': 'ultra_honk',
        'hash': '0x' + digest.hex(),
        'vk': ['0x' + words[i : i + 32].hex() for i in range(0, len(words), 32)],
    }


def generate(vk_path, output):
    source = render(circuit_module(load_key(vk_path)))
    with open(output, 'x') as file:
        file.write(source)


def generate_from_circuit(circuit, output):
    """Run the pinned bb write_vk on a compiled Noir circuit, then generate."""
    from toolchain import run

    with tempfile.TemporaryDirectory() as directory:
        run(
            'barretenberg',
            'write_vk',
            '-b',
            Path(circuit).resolve(),
            '-o',
            directory,
            '--verifier_target',
            'evm',
            '-c',
            ROOT / '.tools/crs',
        )
        generate(Path(directory) / 'vk', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('-b', '--circuit', help='compiled Noir circuit (nargo target/*.json)')
    source.add_argument('-k', '--vk', help='bb write_vk output: binary vk (with vk_hash) or vk.json')
    parser.add_argument('-o', '--output', required=True, help='new .fe file to write')
    args = parser.parse_args()
    try:
        if args.circuit:
            generate_from_circuit(args.circuit, args.output)
        else:
            generate(args.vk, args.output)
    except (ValueError, KeyError, FileExistsError) as error:
        raise SystemExit(f'error: {error}') from None
    print(args.output)
