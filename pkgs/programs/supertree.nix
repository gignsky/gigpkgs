{ pkgs, ... }:
let
  pkg = pkgs.writeShellScriptBin "supertree" ''
    ${pkgs.tree}/bin/tree ..
  '';
in
pkg
// {
  passthru.tests = {
    basic = pkgs.runCommand "supertree-test" { buildInputs = [ pkg ]; } ''
      set -e
      # Should print something, check for a known directory in the output
      supertree > $out
      grep -q "home" $out
    '';
  };
}
