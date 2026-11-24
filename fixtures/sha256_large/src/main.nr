// SHA-256 of exactly 4096 private bytes, checked against eight public u32 words.
// Includes standard SHA-256 padding: 64 data blocks plus one padding block.
fn main(message: [u8; 4096], digest: pub [u32; 8]) {
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    for block_index in 0..64 {
        let mut block: [u32; 16] = [0; 16];
        for word in 0..16 {
            let offset = block_index * 64 + word * 4;
            block[word] = (message[offset] as u32) * 0x1000000
                + (message[offset + 1] as u32) * 0x10000
                + (message[offset + 2] as u32) * 0x100
                + (message[offset + 3] as u32);
        }
        state = std::hash::sha256_compression(block, state);
    }
    let mut padding: [u32; 16] = [0; 16];
    padding[0] = 0x80000000;
    padding[15] = 4096 * 8;
    state = std::hash::sha256_compression(padding, state);
    assert(state == digest);
}
