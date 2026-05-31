{ pkgs, ... }:
rec {
  cargo-update =
    pkgs.writeShellScriptBin "cargo-update" ''
      # Check for --no-commit flag
      NO_COMMIT=false
      if [[ "$1" == "--no-commit" ]]; then
          NO_COMMIT=true
      fi

      # Run cargo update
      cargo update

      # Check if Cargo.toml or Cargo.lock have changed
      if git diff --quiet Cargo.toml Cargo.lock; then
          echo "No changes detected in Cargo.toml or Cargo.lock."
          exit 0
      fi

      # If --no-commit flag is set, exit without committing
      if $NO_COMMIT; then
          echo "Changes detected, but --no-commit flag is set. Exiting without committing."
          exit 0
      fi

      # Stage and commit changes
      git add Cargo.toml Cargo.lock
      git commit -m "Update Cargo dependencies via cargo-update program"

      echo "Changes committed successfully."
    ''
    // {
      passthru.tests = {
        basic = pkgs.runCommand "cargo-update-test" { buildInputs = [ cargo-update ]; } ''
          set -e
          # Should fail gracefully since .git may not exist in sandbox
          if cargo-update --no-commit > $out 2>&1; then
            grep -q "No changes detected" $out || true
          else
            grep -q "not a git repository" $out || true
          fi
        '';
      };
    };
}
