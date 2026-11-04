//! The JPEG XL encoder is C++. On Android the NDK's `libstdc++` that
//! `jpegxl-src` links is an empty stub, so without this the library loads
//! with `operator delete` and friends undefined and the app cannot start.
//! These come last on the link line, after everything that needs them.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-link-arg=-lc++_static");
        println!("cargo:rustc-link-arg=-lc++abi");
    }
}
