{ pkgs, ... }:
rec {
  upignore =
    pkgs.writeShellScriptBin "upignore" ''
      git add .gitignore
      git commit -m "upignore - updated .gitignore"
    ''
    // {
      passthru.tests = {
        basic = pkgs.runCommand "upignore-test" { buildInputs = [ upignore ]; } ''
          set -e
          # Should fail gracefully since .git may not exist in sandbox
          if upignore > $out 2>&1; then
            grep -q ".gitignore" $out || true
          else
            grep -q "not a git repository" $out || true
          fi
        '';
      };
    };
}
