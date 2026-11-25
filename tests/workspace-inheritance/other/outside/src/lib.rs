#[cfg(all(feature = "a", feature = "b"))]
pub fn hello() -> &'static str {
    "Hello, world!"
}
