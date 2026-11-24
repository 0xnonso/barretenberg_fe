// The same eight signature checks as ecdsa_batch, with one public commitment
// binding all public keys and the message hash. The application must check that
// commitment against its intended signers/message; it is part of the statement.
fn main(
    public_key_x: [[u8; 32]; 8],
    public_key_y: [[u8; 32]; 8],
    signatures: [[u8; 64]; 8],
    message_hash: [u8; 32],
) -> pub Field {
    let mut commitment = 0;
    for signer in 0..8 {
        assert(std::ecdsa_secp256k1::verify_signature(
            public_key_x[signer], public_key_y[signer], signatures[signer], message_hash,
        ));
        commitment = bind(commitment, public_key_x[signer], (2 * signer + 1) as Field);
        commitment = bind(commitment, public_key_y[signer], (2 * signer + 2) as Field);
    }
    bind(commitment, message_hash, 17)
}

fn bind(previous: Field, bytes: [u8; 32], domain: Field) -> Field {
    let mut high: Field = 0;
    let mut low: Field = 0;
    for i in 0..16 {
        high = high * 256 + bytes[i] as Field;
        low = low * 256 + bytes[i + 16] as Field;
    }
    std::hash::poseidon2_permutation([previous, high, low, domain])[0]
}
