# Testing

All commands run from the repo root. Tests are flake checks: Nix-level unit tests (`_00xx`–`_02xx`) and fixture builds under `tests/` (`_1xxx`).

```bash
nix flake check                                   # everything
nix build .#checks.x86_64-linux._1000-hello-worlds-features-release   # 1 check
nix eval --json .#checks.x86_64-linux --apply builtins.attrNames      # list checks
```

## Adding a Regression Test

Every fixed corner case gets a test:

1. Nix library logic: add a case to the `*-tests` attrset next to the code in `lib/`
2. Build behavior: add a crate printing `Hello, world!` under `tests/<name>/` with a `Cargo.lock`, and list it in `_1000-hello-worlds` in `tests/default.nix`; it is built in both `dev` and `release` profiles
3. Output layout: add a `runCommand` check to `tests/default.nix`, like `_1001-dev-output-has-no-lib`
