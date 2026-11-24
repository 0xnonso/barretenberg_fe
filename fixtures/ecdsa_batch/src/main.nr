// Eight independent signers of one public message hash: 544 public byte inputs.
// Signatures are private. Keys and signatures in this fixture are synthetic.
fn main(
    public_key_x: pub [[u8; 32]; 8],
    public_key_y: pub [[u8; 32]; 8],
    signatures: [[u8; 64]; 8],
    message_hash: pub [u8; 32],
) {
    for signer in 0..8 {
        assert(std::ecdsa_secp256k1::verify_signature(
            public_key_x[signer], public_key_y[signer], signatures[signer], message_hash,
        ));
    }
}
