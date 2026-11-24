fn main(values: [u8; 4], sum: pub Field) {
    assert((values[0] as Field) + (values[1] as Field) + (values[2] as Field) + (values[3] as Field) == sum);
    let point = std::hash::pedersen_commitment([values[0] as Field, values[1] as Field, values[2] as Field, values[3] as Field]);
    assert(point.x != 0);
    let digest = std::hash::blake2s(values);
    assert(digest[0] != 0);
}
