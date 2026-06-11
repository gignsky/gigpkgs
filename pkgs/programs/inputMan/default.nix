{ pkgs }:
let
  pkg = pkgs.stdenv.mkDerivation {
    pname = "inputman";
    version = "0.1.0";

    src = ./.;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      mkdir -p $out/bin
      cp ${./inputMan.sh} $out/bin/inputman
      chmod +x $out/bin/inputman

      wrapProgram $out/bin/inputman \
        --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.nix
            pkgs.git
            pkgs.jq
            pkgs.perl
          ]
        }
    '';

    meta = {
      description = "Manage flake inputs for gigpkgs";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.unix;
    };
  };
in
pkg
// {
  passthru.tests = {
    help-output =
      pkgs.runCommand "inputman-help-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman --help > help_output

          grep -q "install <url>" help_output
          grep -q "update <name>" help_output
          grep -q "remove <name>" help_output
          grep -q -- "--follows" help_output
          grep -q -- "--no-info" help_output
          grep -q -- "--no-branch" help_output
          grep -q -- "--no-commit" help_output

          echo "Help output verified" > $out
        '';

    unknown-command =
      pkgs.runCommand "inputman-unknown-command-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          if inputman unknown-subcommand > output 2>&1; then
            echo "Unknown subcommand should fail"
            cat output
            exit 1
          fi

          grep -q "Unknown command" output
          echo "Unknown command handling verified" > $out
        '';

    infer-name =
      pkgs.runCommand "inputman-infer-name-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          actual=$(inputman __infer-name "github:gignsky/gigvim?ref=main")
          test "$actual" = "gigvim"
          echo "infer_name verified" > $out
        '';

    discover-fallback =
      pkgs.runCommand "inputman-discover-fallback-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          inputman __discover-packages "not-a-valid-flake-url" "x86_64-linux" > output 2> errors
          grep -q "^default$" output
          grep -q "falling back\|No packages discovered" errors
          echo "discover_packages fallback verified" > $out
        '';

    patch-flake-add =
      pkgs.runCommand "inputman-patch-flake-add-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          cat > flake.nix <<'FLAKE'
          {
              inputs = {
                  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
                  # keep this comment near closing
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          inputman __patch-flake-add gigvim github:gignsky/gigvim nixpkgs=nixpkgs

          grep -q 'gigvim.url = "github:gignsky/gigvim";' flake.nix
          grep -q 'gigvim.inputs.nixpkgs.follows = "nixpkgs";' flake.nix
          grep -q '# keep this comment near closing' flake.nix

          echo "patch_flake_add verified" > $out
        '';

    script-syntax =
      pkgs.runCommand "inputman-syntax-test"
        {
          buildInputs = [
            pkg
            pkgs.bash
          ];
        }
        ''
          set -e
          bash -n $(command -v inputman)
          echo "Script syntax verified" > $out
        '';

    dependencies =
      pkgs.runCommand "inputman-dependencies-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          command -v inputman > /dev/null
          command -v nix > /dev/null
          command -v git > /dev/null
          command -v jq > /dev/null
          command -v perl > /dev/null
          echo "Runtime dependencies verified" > $out
        '';

    shellcheck =
      pkgs.runCommand "inputman-shellcheck-test"
        {
          buildInputs = [ pkgs.shellcheck ];
        }
        ''
          set -e
          shellcheck ${./inputMan.sh}
          echo "shellcheck passed" > $out
        '';
  };
}
