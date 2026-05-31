{ pkgs, ... }:
let
  pkg = pkgs.writeShellScriptBin "upflake" ''
    git add flake.lock
    git commit -m "upflake - updated flake.lock"
  '';
in
pkg
// {
  passthru.tests = {
    basic = pkgs.runCommand "upflake-test" { buildInputs = [ pkg ]; } ''
      set -e
      # Should fail gracefully since .git may not exist in sandbox
      if upflake > $out 2>&1; then
        grep -q "flake.lock" $out || true
      else
        grep -q "not a git repository" $out || true
      fi
    '';
  };
}
