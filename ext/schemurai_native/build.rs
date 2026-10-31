use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=protocol.def");
    let definitions = fs::read_to_string("protocol.def").expect("read native protocol");
    let mut output = String::new();
    for line in definitions.lines() {
        let (fields, prefix) = if let Some(fields) = line.strip_prefix("SN_OPCODE(") {
            (fields, "OP_")
        } else if let Some(fields) = line.strip_prefix("SN_FIELD(") {
            (fields, "FIELD_")
        } else if let Some(fields) = line.strip_prefix("SN_CONSTANT(") {
            (fields, "")
        } else {
            continue;
        };
        let fields: Vec<_> = fields
            .strip_suffix(')')
            .expect("protocol closing parenthesis")
            .split(',')
            .map(str::trim)
            .collect();
        assert_eq!(fields.len(), if prefix.is_empty() { 2 } else { 3 });
        let name = fields[0];
        assert!(
            name.bytes()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_')
        );
        let value: i32 = fields[if prefix.is_empty() { 1 } else { 2 }]
            .parse()
            .expect("protocol integer value");
        output.push_str(&format!("pub const {prefix}{name}: i32 = {value};\n"));
    }
    let directory = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo output directory"));
    fs::write(directory.join("protocol.rs"), output).expect("write native protocol constants");
}
