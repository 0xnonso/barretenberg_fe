// Four independent depth-32 membership paths. The returned roots are public.
// This fixture uses Poseidon2([left, right, 2, 0])[0] as its node hash.
fn main(leaves: [Field; 4], siblings: [[Field; 32]; 4], indices: [u32; 4]) -> pub [Field; 4] {
    let mut roots = [0; 4];
    for path in 0..4 {
        let mut node = leaves[path];
        for level in 0..32 {
            let right = ((indices[path] >> level) & 1) == 1;
            let left_child = if right { siblings[path][level] } else { node };
            let right_child = if right { node } else { siblings[path][level] };
            node = std::hash::poseidon2_permutation([left_child, right_child, 2, 0])[0];
        }
        roots[path] = node;
    }
    roots
}
