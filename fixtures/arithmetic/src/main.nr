// The verifier learns result, but does not receive a or b.
fn main(a: Field, b: Field, result: pub Field) {
    assert(a * b == result);
}

#[test]
fn multiplication() {
    main(3, 4, 12);
}
