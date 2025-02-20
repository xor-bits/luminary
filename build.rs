use std::{env, path::Path, process::Command};

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();
    let dest = Path::new(&out_dir).join("shader.comp.spirv");

    let status = Command::new("glslc")
        .arg("-DCOMP=1")
        .arg("-fshader-stage=comp")
        .arg("./src/graphics/shader.glsl")
        .arg("-o")
        .arg(dest)
        .status()
        .unwrap();
    if !status.success() {
        panic!();
    }
}
