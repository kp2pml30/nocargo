{ lib, pkgs }:
let
  inherit (lib) optionalAttrs elem;
in
with pkgs;
{
  libz-sys =
    { features, ... }:
    optionalAttrs (!elem "static" features) {
      nativeBuildInputs = [ pkg-config ];
      propagatedBuildInputs = [ zlib ];
    };

  mlua-sys =
    { features, ... }:
    let
      has = feature: elem feature features;
      lua =
        if has "luajit" || has "luajit52" then
          luajit
        else if has "lua54" then
          lua5_4
        else if has "lua53" then
          lua5_3
        else if has "lua52" then
          lua5_2
        else
          lua5_1;
    in
    # Luau is always vendored.
    optionalAttrs (!has "vendored" && !has "luau" && !has "module") {
      nativeBuildInputs = [ pkg-config ];
      propagatedBuildInputs = [ lua ];
    };

  openssl-sys =
    { features, ... }:
    optionalAttrs (!elem "vendored" features) {
      nativeBuildInputs = [ pkg-config ];
      propagatedBuildInputs = [ openssl ];
    };
}
