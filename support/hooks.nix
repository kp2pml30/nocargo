{ pkgs }:
let
  python = "${pkgs.python3}/bin/python3";
in
{
  check-commit-message = {
    enable = true;
    name = "check commit message";
    description = "Validate the commit message against conventional-commit rules.";
    entry = "${python} ${./scripts/check-commit-message.py} --message-file";
    language = "system";
    stages = [ "commit-msg" ];
  };

  trim-trailing-whitespace.enable = true;
  end-of-file-fixer.enable = true;
  check-added-large-files.enable = true;
  check-json.enable = true;
  check-yaml.enable = true;
  check-toml.enable = true;
  check-merge-conflicts.enable = true;
  editorconfig-checker = {
    enable = true;
    types = [ "text" ];
    # Formatters below own these.
    excludes = [
      "\\.(nix|toml|rs|md|ya?ml|json)$"
      "(^|/)Cargo\\.lock$"
    ];
  };

  check-source-text = {
    enable = true;
    name = "check-source-text";
    entry = "${python} ${./scripts/check-source-text.py}";
    files = "\\.(rs|py|nix|sh)$";
  };

  markdown-local-links = {
    enable = true;
    name = "markdown-local-links";
    entry = "${python} ${./scripts/md-local-links.py}";
    types = [ "markdown" ];
  };

  check-github-workflows = {
    enable = true;
    name = "check-github-workflows";
    entry = "${pkgs.check-jsonschema}/bin/check-jsonschema --builtin-schema vendor.github-workflows";
    files = "^\\.github/workflows/.*\\.ya?ml$";
  };

  nixfmt.enable = true;
  taplo = {
    enable = true;
    excludes = [ "(^|/)Cargo\\.lock$" ];
  };

  rustfmt = {
    enable = true;
    name = "rustfmt";
    description = "Format Rust code.";
    package = pkgs.rustfmt;
    entry = "${pkgs.rustfmt}/bin/rustfmt --edition 2021";
    files = "\\.rs$";
    pass_filenames = true;
  };

  prettier = {
    enable = true;
    files = "\\.(json|md|ya?ml)$";
  };
}
