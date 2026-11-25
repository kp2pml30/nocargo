fn main() {
    // Describes the crate profile, not the build-override one.
    let profile = std::env::var("PROFILE").unwrap();
    let opt_level = std::env::var("OPT_LEVEL").unwrap();
    let expected = if opt_level == "0" { "debug" } else { "release" };
    assert_eq!(profile, expected, "OPT_LEVEL={opt_level}");

    println!("cargo::rustc-check-cfg=cfg(new_syntax)");
    println!("cargo::rustc-cfg=new_syntax");
    println!("cargo::rustc-env=GREETING=Hello, world!");
}
