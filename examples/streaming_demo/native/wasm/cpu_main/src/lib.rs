use wasm_bindgen::prelude::*;

fn emit_progress(percent: u32) {
    exclosured_guest::emit("progress", &format!(r#"{{"percent":{}}}"#, percent));
}

#[wasm_bindgen]
pub fn burn(iterations: u32) -> u32 {
    let checkpoint = (iterations / 10).max(1);
    let mut acc = 0x9e37_79b9_u32;

    for i in 0..iterations {
        acc = mix(acc ^ i);

        if i % checkpoint == 0 {
            emit_progress(i.saturating_mul(100) / iterations.max(1));
        }
    }

    emit_progress(100);
    acc
}

fn mix(value: u32) -> u32 {
    let value = value ^ value.rotate_left(13);
    value.wrapping_mul(0x85eb_ca6b).rotate_right(7)
}
