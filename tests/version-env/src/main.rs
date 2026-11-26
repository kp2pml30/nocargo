fn main() {
    assert_eq!(env!("CARGO_PKG_VERSION"), "1.2.3-alpha.1+build.5");
    assert_eq!(env!("CARGO_PKG_VERSION_MAJOR"), "1");
    assert_eq!(env!("CARGO_PKG_VERSION_MINOR"), "2");
    assert_eq!(env!("CARGO_PKG_VERSION_PATCH"), "3");
    assert_eq!(env!("CARGO_PKG_VERSION_PRE"), "alpha.1");
    println!("Hello, world!");
}
