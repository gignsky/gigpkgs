{ pkgs, ... }:
rec {
  supertree =
    pkgs.writeShellScriptBin "supertree" ''
      ${pkgs.tree}/bin/tree ..
    ''
    // {
      passthru.tests = {
        basic = pkgs.runCommand "supertree-test" { buildInputs = [ supertree ]; } ''
          set -e
          # Should print something, check for a known directory in the output
          supertree > $out
          grep -q "home" $out
        '';
      };
    };
}
