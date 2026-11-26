{
  pkgs,
  self,
  inputs,
  defaultRegistries,
}:
let
  inherit (pkgs.lib)
    mapAttrs
    attrNames
    attrValues
    assertMsg
    head
    ;
  inherit (self.lib.${pkgs.stdenv.hostPlatform.system}) mkRustPackageOrWorkspace;

  git-semver-1-0-0 = builtins.fetchTarball {
    url = "https://github.com/dtolnay/semver/archive/1.0.0/master.tar.gz";
    sha256 = "0s7gwj5l0h98spgm7vyxak9z3hgrachwxbnf1fpry5diz939x8n4";
  };

  git-semver-1-0-12 = builtins.fetchTarball {
    url = "https://github.com/dtolnay/semver/archive/1.0.4/master.tar.gz";
    sha256 = "1l2nkfmjgz2zkqw03hmy66q0v1rxvs7fc4kh63ph4lf1924wrmix";
  };

  gitSrcs = {
    "https://github.com/dtolnay/semver?tag=1.0.0" = git-semver-1-0-0;
    "http://github.com/dtolnay/semver" = git-semver-1-0-12; # v1, v2
    "http://github.com/dtolnay/semver?branch=master" = git-semver-1-0-12; # v3
    "ssh://git@github.com/dtolnay/semver?rev=a2ce5777dcd455246e4650e36dde8e2e96fcb3fd" =
      git-semver-1-0-0;
    "ssh://git@github.com/dtolnay/semver" = git-semver-1-0-12;
    "https://example.com/repo?rev=0123456789abcdef0123456789abcdef01234567" = ./git-workspace/repo;
  };

  extraRegistries = {
    "https://www.github.com/rust-lang/crates.io-index" = head (attrValues defaultRegistries);
  };

  shouldBeHelloWorld =
    drv:
    pkgs.runCommand "${drv.name}" { } ''
      binaries=(${drv.bin}/bin/*)
      [[ ''${#binaries[@]} == 1 ]]
      got="$(''${binaries[0]})"
      expect="Hello, world!"
      echo "Got   : $got"
      echo "Expect: $expect"
      [[ "$got" == "$expect" ]]
      touch $out
    '';

  mkHelloWorldTest =
    src:
    let
      ws = mkRustPackageOrWorkspace {
        inherit src gitSrcs extraRegistries;
      };
      profiles = mapAttrs (_: pkgs: shouldBeHelloWorld (head (attrValues pkgs))) ws;
    in
    {
      inherit (profiles) dev release;
    };

  mkWorkspaceTest =
    src: expectMembers:
    let
      ws = mkRustPackageOrWorkspace { inherit src; };
      gotMembers = attrNames ws.dev;
    in
    assert assertMsg (gotMembers == expectMembers) ''
      Member assertion failed.
      expect: ${toString expectMembers}
      got:    ${toString gotMembers}
    '';
    ws;
in
{
  _1000-hello-worlds =
    mapAttrs (name: path: mkHelloWorldTest path) {
      build-deps = ./build-deps;
      build-script-env = ./build-script-env;
      build-feature-env-vars = ./build-feature-env-vars;
      cap-lints = ./cap-lints;
      crate-names = ./crate-names;
      custom-lib-name = ./custom-lib-name;
      dependency-v1 = ./dependency-v1;
      dependency-v2 = ./dependency-v2;
      dependency-v3 = ./dependency-v3;
      features = ./features;
      git-workspace = ./git-workspace/app;
      include-outside = ./include-outside;
      libz-dynamic = ./libz-dynamic;
      libz-static = ./libz-static;
      lto-fat = ./lto-fat;
      lto-mixed-crate-types = ./lto-mixed-crate-types;
      lto-proc-macro = ./lto-proc-macro;
      lto-thin = ./lto-thin;
      outside-lib-path = ./outside-lib-path/crate;
      tokio-app = ./tokio-app;
      version-env = ./version-env;
      workspace-inheritance = ./workspace-inheritance/ws;
    }
    // {
      workspace-inline = mkWorkspaceTest ./workspace-inline [
        "bar"
        "baz"
        "foo"
      ];
      workspace-proc-macro-lto = mkWorkspaceTest ./workspace-proc-macro-lto [
        "acro"
        "procm"
      ];
      workspace-virtual = mkWorkspaceTest ./workspace-virtual [
        "bar"
        "foo"
      ];
    };

  # `lib` dirs in propagated outputs make ld-wrapper add flags per crate, overflowing the environment.
  _1001-dev-output-has-no-lib =
    let
      bar = (mkRustPackageOrWorkspace { src = ./workspace-virtual; }).release.bar;
    in
    pkgs.runCommand "dev-output-has-no-lib" { } ''
      [[ -e ${bar.dev}/rust-lib && ! -e ${bar.dev}/lib ]]
      if grep -qF ${bar.out} ${bar.dev}/nix-support/propagated-build-inputs 2>/dev/null; then exit 1; fi
      touch $out
    '';

  # Binaries are named after the target, not the underscored crate name.
  _1002-bin-name-keeps-hyphens =
    let
      app = (mkRustPackageOrWorkspace { src = ./tokio-app; }).release.tokio-app;
    in
    pkgs.runCommand "bin-name-keeps-hyphens" { } ''
      [[ -x ${app.bin}/bin/tokio-app ]]
      touch $out
    '';

  # A path dependency missing from `src` is taken from `pathSrcs` and patched by an override.
  _1003-path-srcs =
    let
      ws = mkRustPackageOrWorkspace {
        # A store path string, as `lib.fileset.toSource` gives.
        src = builtins.path { path = ./path-srcs/app; };
        pathSrcs."third-party/vendored" = ./path-srcs/vendored;
        buildCrateOverrides.vendored = old: { patches = [ ./path-srcs/greeting.patch ]; };
      };
    in
    mapAttrs (_: pkgs: shouldBeHelloWorld pkgs.path-srcs) { inherit (ws) dev release; };
}
