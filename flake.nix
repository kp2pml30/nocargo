{
  description = "Build Rust crates with Nix, 1 derivation per crate";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    registry-crates-io = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      registry-crates-io,
      ...
    }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;

      inherit (builtins) toJSON typeOf;
      inherit (nixpkgs.lib)
        isDerivation
        isFunction
        isAttrs
        mapAttrs
        mapAttrsToList
        listToAttrs
        flatten
        ;

      nocargo-lib = import ./lib { inherit (nixpkgs) lib; };

      perSystem = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          defaultRegistries = {
            "https://github.com/rust-lang/crates.io-index" =
              nocargo-lib.pkg-info.mkIndex pkgs.fetchurl registry-crates-io
                (
                  import ./crates-io-override {
                    inherit (nixpkgs) lib;
                    inherit pkgs;
                  }
                );
          };
        in
        rec {
          # Is there a better place? `naersk` places builders under `lib.${system}`.
          lib = rec {
            mkIndex = nocargo-lib.pkg-info.mkIndex pkgs.fetchurl;
            buildRustCrate = pkgs.callPackage ./build-rust-crate {
              inherit nocargo-lib;
            };
            mkRustPackageOrWorkspace = pkgs.callPackage nocargo-lib.support.mkRustPackageOrWorkspace {
              inherit defaultRegistries buildRustCrate;
            };
          };

          checks =
            let
              okDrv = derivation {
                name = "success";
                inherit system;
                builder = "/bin/sh";
                args = [
                  "-c"
                  ": >$out"
                ];
              };

              checkArgs = {
                inherit pkgs defaultRegistries;

                assertEq = got: expect: {
                  __assertion = true;
                  fn =
                    name:
                    if toJSON got == toJSON expect then
                      okDrv
                    else
                      pkgs.runCommand name
                        {
                          nativeBuildInputs = [ pkgs.jq ];
                          got = toJSON got;
                          expect = toJSON expect;
                        }
                        ''
                          if [[ ''${#got} < 32 && ''${#expect} < 32 ]]; then
                            echo "got:    $got"
                            echo "expect: $expect"
                          else
                            echo "got:"
                            jq . <<<"$got"
                            echo
                            echo "expect:"
                            jq . <<<"$expect"
                            echo
                            echo "diff:"
                            diff -y <(jq . <<<"$got") <(jq . <<<"$expect")
                            exit 1
                          fi
                        '';
                };
              };

              tests =
                with nocargo-lib;
                {
                  _0000-semver-compare = semver.semver-compare-tests;
                  _0001-semver-req = semver.semver-req-tests;
                  _0002-cfg-parser = target-cfg.cfg-parser-tests;
                  _0003-cfg-eval = target-cfg.cfg-eval-tests;
                  _0004-platform-cfg = target-cfg.platform-cfg-tests;
                  _0005-glob = glob.glob-tests;
                  _0006-sanitize-relative-path = support.sanitize-relative-path-tests;

                  _0100-pkg-info-from-toml = pkg-info.pkg-info-from-toml-tests;
                  _0101-pkg-info-from-registry = pkg-info.pkg-info-from-registry-tests;
                  _0103-resolve-feature = resolve.resolve-feature-tests;

                  _0200-resolve-deps = resolve.resolve-deps-tests;
                  _0201-build-from-src-dry = support.build-from-src-dry-tests;
                }
                // import ./tests {
                  inherit
                    pkgs
                    self
                    inputs
                    defaultRegistries
                    ;
                };

              flattenTests =
                prefix: v:
                if isDerivation v then
                  {
                    name = prefix;
                    value = v;
                  }
                else if v ? __assertion then
                  {
                    name = prefix;
                    value = v.fn prefix;
                  }
                else if isFunction v then
                  flattenTests prefix (v checkArgs)
                else if isAttrs v then
                  mapAttrsToList (name: flattenTests "${prefix}-${name}") v
                else
                  throw "Unexpect test type: ${typeOf v}";

              tests' = listToAttrs (flatten (mapAttrsToList flattenTests tests));

            in
            tests'
            // {
              pre-commit-check = inputs.git-hooks.lib.${system}.run {
                src = ./.;
                hooks = import ./support/hooks.nix { inherit pkgs; };
              };
            };
        }
      );
    in
    {
      lib = mapAttrs (_: s: s.lib) perSystem;
      checks = mapAttrs (_: s: s.checks) perSystem;

      formatter = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.checks.${system}.pre-commit-check.config) package configFile;
        in
        pkgs.writeShellScriptBin "pre-commit-run" ''
          ${pkgs.lib.getExe package} run --all-files --config ${configFile}
        ''
      );

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.checks.${system}.pre-commit-check) shellHook enabledPackages;
        in
        {
          default = pkgs.mkShell {
            inherit shellHook;
            buildInputs = enabledPackages;
          };
        }
      );
    };
}
