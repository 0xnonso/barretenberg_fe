fn main(values: [u32; 4], sum: pub Field, product: pub Field) {
    let mut total: Field = 0;
    let mut multiplied: Field = 1;
    for i in 0..4 {
        assert(values[i] < 1000);
        total += values[i] as Field;
        multiplied *= values[i] as Field;
    }
    assert(total == sum);
    assert(multiplied == product);
    // Exercise range/lookup gates alongside nonlinear field arithmetic.
    let digest = std::hash::poseidon2_permutation([values[0] as Field, values[1] as Field, values[2] as Field, values[3] as Field]);
    assert(digest[0] != 0);
}
