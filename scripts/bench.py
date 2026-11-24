"""Fe vs Barretenberg: sizes, deployment estimates and Forge verify gas medians.

    python3 scripts/bench.py             rebuild, then print Markdown tables
    python3 scripts/bench.py --no-build  reuse current out/corpus artifacts
    python3 scripts/bench.py --profile   include precompile execution gas/counts

Uses Aztec's barretenberg/sol/bootstrap.sh measurement: Forge's JSON gas report,
functions["verify(bytes,bytes32[])"].median. Each fixture runs separately so
medians never mix circuits. Results use Aztec's name/value/unit JSON format.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict

import build
from toolchain import LOCK, ROOT, tool

PRECOMPILES = ('modexp', 'ecmul', 'ecadd', 'ecpairing')
SIGNATURE = 'verify(bytes,bytes32[])'
REPORT_TARGETS = {'FeGasReportTarget': 'Fe', 'SolidityGasReportTarget': 'Solidity'}
UPSTREAM = (
    'https://github.com/AztecProtocol/aztec-packages/blob/'
    '0219f11d8133970df3974fe5ae65e006bf8c193a/barretenberg/sol/bootstrap.sh'
)


def calldata_gas(*files):
    """Base and calldata cost added to the harness's measured CREATE gas."""
    return sum(21000 + sum(16 if byte else 4 for byte in path.read_bytes()) for path in files)


def precompile_profile(trace):
    """Only the two report targets' verify calls; exclude setup and other calls."""
    profiles, current = {}, None
    for line in trace.splitlines():
        match = re.match(r'^ {4}├─ \[\d+\] (FeGasReportTarget|SolidityGasReportTarget)::verify\(', line)
        if match:
            side = REPORT_TARGETS[match[1]]
            assert side not in profiles, f'Duplicate {side} verification trace'
            current = defaultdict(lambda: [0, 0])
            profiles[side] = current
        elif re.match(r'^ {4}[├└]─ ', line):
            current = None
        elif current is not None and (match := re.search(r'\[(\d+)\] PRECOMPILES::(\w+)\(', line)):
            current[match[2]][0] += int(match[1])
            current[match[2]][1] += 1
    assert set(profiles) == {'Fe', 'Solidity'}, 'Missing verification traces'
    return profiles


def report_medians(report):
    medians = {}
    for contract in report:
        name = contract['contract'].rsplit(':', 1)[-1]
        if name not in REPORT_TARGETS:
            continue
        measurement = contract['functions'][SIGNATURE]
        assert measurement['calls'] == 1, f'Expected one valid proof call for {name}'
        side = REPORT_TARGETS[name]
        assert side not in medians, f'Duplicate gas report for {side}'
        medians[side] = measurement['median']
    assert set(medians) == {'Fe', 'Solidity'}, 'Missing verifier gas report'
    return medians


def forge(*args, gas_report=False):
    result = subprocess.run(
        [
            tool('forge'),
            'test',
            '--offline',
            '--evm-version',
            LOCK['evm_version'],
            '--match-contract',
            '^BenchTest$',
            *([] if '--json' in args else ['--color', 'never']),
            *args,
        ],
        cwd=ROOT,
        env=os.environ | {'FORGE_GAS_REPORT': str(gas_report).lower()},
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return result.stdout


def table(header, lines):
    print('| ' + ' | '.join(header) + ' |\n|---|' + '---:|' * (len(header) - 1))
    for line in lines:
        print('| ' + ' | '.join(line) + ' |')
    print()


def main():
    if '--no-build' not in sys.argv:
        build.corpus()
    profile = '--profile' in sys.argv
    # Keep gas-report transaction accounting out of the CREATE measurements:
    # calldata_gas() adds their transaction costs separately below.
    output = forge('-vvvv' if profile else '-vv')
    metrics, tests, profiles = defaultdict(dict), {}, {}
    # Anchor metric matching to log lines: unanchored scans of proof hex in full
    # traces cause quadratic regex backtracking.
    for name, key, value in re.findall(r'^\s*(\w+)\.(\w+): (\d+)$', output, re.MULTILINE):
        metrics[name][key] = int(value)
    for block in re.split(r'\n\[PASS\] ', output)[1:]:
        fixture = re.search(r'^\s*(\w+)\.runtime_bytes:', block, re.MULTILINE)[1]
        tests[fixture] = re.match(r'(\w+)\(\)', block)[1]
        if profile:
            profiles[fixture] = precompile_profile(block)
    assert set(metrics) == set(tests) == set(build.FIXTURES), 'Incomplete benchmark corpus'

    entries = []
    reports = {}
    for name in sorted(metrics):
        report = json.loads(forge('--match-test', rf'^{tests[name]}\(\)$', '--json', gas_report=True))
        reports[name] = report
        gas = report_medians(report)
        metrics[name]['fe_gas'], metrics[name]['solidity_gas'] = gas['Fe'], gas['Solidity']
        entries.extend({'name': f'{name}/{side}', 'value': value, 'unit': 'gas'} for side, value in gas.items())
    out = ROOT / 'out/bench'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'verifier.bench.json').write_text(json.dumps(entries, indent=2) + '\n')
    (out / 'forge-gas-reports.json').write_text(json.dumps(reports, indent=2) + '\n')
    (out / 'metadata.json').write_text(
        json.dumps(
            {
                'evm_version': LOCK['evm_version'],
                'metric': f'functions["{SIGNATURE}"].median',
                'upstream': UPSTREAM,
                'toolchain': LOCK,
            },
            indent=2,
        )
        + '\n'
    )

    rows = sorted(metrics.items(), key=lambda item: item[1]['fe_gas'])
    m0 = rows[0][1]
    print(f'## Contract size (bytes; EVM: {LOCK["evm_version"]})\n')
    size_rows = [
        min(rows, key=lambda item: item[1]['solidity_verifier_bytes']),
        max(rows, key=lambda item: item[1]['solidity_verifier_bytes']),
    ]
    table(
        ['', 'Verifier', 'Libraries', 'Total'],
        [
            [
                'Fe (all fixtures)',
                f'{m0["runtime_bytes"]:,}',
                f'{m0["relations_bytes"]:,}',
                f'{m0["runtime_bytes"] + m0["relations_bytes"]:,}',
            ],
            *[
                [
                    f'Solidity ({name})',
                    f'{m["solidity_verifier_bytes"]:,}',
                    f'{m["solidity_relations_bytes"] + m["solidity_transcript_bytes"]:,}',
                    format(
                        m['solidity_verifier_bytes'] + m['solidity_relations_bytes'] + m['solidity_transcript_bytes'],
                        ',',
                    ),
                ]
                for name, m in size_rows
            ],
        ],
    )
    print('## Deployment gas estimates\n')
    lines = []
    for name, m in rows:
        corpus = ROOT / 'out/corpus' / name
        fe = m['deployment_gas'] + calldata_gas(corpus / 'fe.bin')
        solidity = m['solidity_deployment_gas'] + calldata_gas(
            corpus / 'solidity.bin', corpus / 'RelationsLib.bin', corpus / 'ZKTranscriptLib.bin'
        )
        shared = m['solidity_verifier_deployment_gas'] + calldata_gas(corpus / 'solidity.bin')
        lines.append([name, f'{fe:,}', f'{solidity:,}', f'{shared:,}'])
    table(['Fixture', 'Fe (1 tx)', 'Solidity, fresh libraries (3 txs)', 'Solidity, reused libraries (1 tx)'], lines)

    print('## Verification gas (Forge gas-report median, Aztec benchmark method)\n')
    lines = []
    for name, m in rows:
        words = (ROOT / 'fixtures' / name / 'artifacts/vk').read_bytes()
        log_n, inputs = int.from_bytes(words[:32], 'big'), int.from_bytes(words[32:64], 'big') - 8
        fe, solidity = m['fe_gas'], m['solidity_gas']
        lines.append([name, str(log_n), str(inputs), f'{fe:,}', f'{solidity:,}', f'{1 - fe / solidity:.0%}'])
    table(['Fixture', 'log_n', 'Inputs', 'Fe gas', 'Solidity gas', 'Saved'], lines)

    if profile:
        print('## Precompile execution (gas / calls; excludes call setup)\n')
        lines = []
        for name, _ in rows:
            for side in ('Fe', 'Solidity'):
                calls = profiles[name][side]
                lines.append([f'{name} {side}', *[f'{calls[p][0]:,} / {calls[p][1]}' for p in PRECOMPILES]])
        table(['Fixture', *PRECOMPILES], lines)
    print('Saved out/bench/verifier.bench.json, forge-gas-reports.json and metadata.json')


if __name__ == '__main__':
    main()
