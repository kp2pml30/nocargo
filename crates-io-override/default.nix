{ lib, pkgs }:
let
  inherit (lib) optionalAttrs elem;
in
with pkgs;
{
  libz-sys = { features, ... }: optionalAttrs (!elem "static" features) {
    nativeBuildInputs = [ pkg-config ];
    propagatedBuildInputs = [ zlib ];
  };

  openssl-sys = { features, ... }: optionalAttrs (!elem "vendored" features) {
    nativeBuildInputs = [ pkg-config ];
    propagatedBuildInputs = [ openssl ];
  };
}
