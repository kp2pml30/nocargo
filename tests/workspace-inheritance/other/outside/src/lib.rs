#[cfg(all(feature = "a", feature = "b", feature = "c"))]
pub fn hello() -> &'static str {
    "Hello, world!"
}
