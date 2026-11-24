"""Check the opening oracle against both pinned Solidity source forms."""

import re

from toolchain import ROOT

LEXEMES = re.compile(
    r"""//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[$\w]+"""
    r'|>>=|<<=|\*\*|\+\+|--|&&|\|\||==|!=|<=|>=|<<|>>|[+*/%&|^\-]=|=>|:=|[^\s]',
    re.S,
)


def tokens(source):
    return [m.group() for m in LEXEMES.finditer(source) if not m.group().startswith(('//', '/*'))]


def function_body(source, name):
    words = tokens(source)
    starts = [i for i in range(len(words) - 1) if words[i : i + 2] == ['function', name]]
    if len(starts) != 1:
        raise ValueError(f'Expected one {name} function')
    start = words.index('{', starts[0])
    depth = 1
    for end in range(start + 1, len(words)):
        depth += (words[end] == '{') - (words[end] == '}')
        if depth == 0:
            return words[start + 1 : end]
    raise ValueError(f'Unclosed {name} function')


def split_once(words, source):
    needle = tokens(source)
    starts = [i for i in range(len(words) - len(needle) + 1) if words[i : i + len(needle)] == needle]
    if len(starts) != 1:
        raise ValueError(f'Expected one instrumentation boundary: {source}')
    start = starts[0]
    return words[:start], words[start + len(needle) :]


def check_opening_adapter(reference, generated, adapter):
    upstream = function_body(reference, 'verifyShplemini')
    if upstream != function_body(generated, 'verifyShplemini'):
        raise ValueError('Readable and generated verifyShplemini implementations differ')
    calculation, _ = split_once(upstream, 'PairingInputs memory pair;')
    before, after = split_once(
        calculation,
        """require(
            checkEvalsConsistency(proof.libraPolyEvals, tp.geminiR, tp.sumCheckUChallenges, proof.libraEvaluation),
            Errors.ConsistencyCheckFailed()
        );""",
    )
    prelude = tokens("""
        Honk.ZKProof memory proof = ZKTranscriptLib.loadProof(data, LOG_N);
        Honk.VerificationKey memory vk = HonkVerificationKey.loadVerificationKey();
        ZKTranscript memory tp = ZKTranscriptLib.generateTranscript(proof,inputs,VK_HASH,NUMBER_OF_PUBLIC_INPUTS,LOG_N);
    """)
    output = tokens("""
        require($MSMSize * 3 == words.length);
        for (uint256 i; i < $MSMSize; ++i) {
            words[3*i] = commitments[i].x;
            words[3*i+1] = commitments[i].y;
            words[3*i+2] = Fr.unwrap(scalars[i]);
        }
    """)
    # Only the separately tested Libra assertion and final pairing are omitted.
    if function_body(adapter, 'terms') != prelude + before + after + output:
        raise ValueError('OpeningReference.terms drifted from the pinned opening calculation')


def check():
    check_opening_adapter(
        (ROOT / 'reference/solidity/honk/BaseZKHonkVerifier.sol').read_text(),
        (ROOT / 'reference/solidity/generated/ArithmeticVerifier.sol').read_text(),
        (ROOT / 'tests/solidity/helpers/OpeningReference.sol').read_text(),
    )


if __name__ == '__main__':
    check()
    print('Opening reference tokens match')
