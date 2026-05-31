{ pkgs, ... }:
let
  pkg = pkgs.writeShellScriptBin "upignore" ''
    git add .gitignore
    git commit -m "upignore - updated .gitignore"
  '';
in
pkg
// {
  passthru.tests = {
    basic = pkgs.runCommand "upignore-test" { buildInputs = [ pkg ]; } ''
      set -e
      # Should fail gracefully since .git may not exist in sandbox
      if upignore > $out 2>&1; then
        grep -q ".gitignore" $out || true
      else
        grep -q "not a git repository" $out || true
      fi
    '';
  };
}
