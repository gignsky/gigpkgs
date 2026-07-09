{ pkgs }:
let
  pkg = pkgs.stdenv.mkDerivation {
    pname = "inputman";
    version = "0.2.0";

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
            pkgs.pre-commit
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
          grep -q -- "--packages, -p" help_output
          grep -q -- "--no-info" help_output
          grep -q -- "--no-branch" help_output
          grep -q -- "--no-modules" help_output
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

    parse-packages-spec =
      pkgs.runCommand "inputman-parse-packages-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          # Legacy include list (no '=')
          inputman __parse-packages-spec myinput "default,cli" > out1
          grep -q "^default=myinput$" out1
          grep -q "^cli=myinput-cli$" out1

          # Key=value aliasing
          inputman __parse-packages-spec myinput "default=app,cli=mycli" > out2
          grep -q "^default=app$" out2
          grep -q "^cli=mycli$" out2

          # Exclusion via '-'
          inputman __parse-packages-spec myinput "default=app,legacy=-" > out3
          grep -q "^default=app$" out3
          if grep -q "legacy" out3; then
            echo "exclusion (=-) not honored"; exit 1
          fi

          echo "parse_packages_spec verified" > $out
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

    patch-flake-add-nested-follows =
      pkgs.runCommand "inputman-patch-flake-nested-follows-test"
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
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          # Slash-separated nested follows
          inputman __patch-flake-add roll-flow github:gignsky/roll-flow gigpkgs/nixpkgs=nixpkgs-master
          grep -q 'roll-flow.inputs.gigpkgs.inputs.nixpkgs.follows = "nixpkgs-master";' flake.nix

          # Dot-separated nested follows
          inputman __patch-flake-add other github:foo/other a.b.c=target
          grep -q 'other.inputs.a.inputs.b.inputs.c.follows = "target";' flake.nix

          # Empty follows (bare -f)
          inputman __patch-flake-add self-follow github:foo/self gigpkgs=
          grep -q 'self-follow.inputs.gigpkgs.follows = "";' flake.nix

          echo "nested follows verified" > $out
        '';

    patch-flake-remove-nested =
      pkgs.runCommand "inputman-patch-flake-remove-nested-test"
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
                  gigvim.url = "github:gignsky/gigvim";
                  gigvim.inputs.nixpkgs.follows = "nixpkgs";
                  gigvim.inputs.gigpkgs.inputs.nixpkgs.follows = "nixpkgs";
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          inputman __patch-flake-remove gigvim

          if grep -q 'gigvim' flake.nix; then
            echo "gigvim references should be gone"; cat flake.nix; exit 1
          fi
          grep -q 'nixpkgs.url' flake.nix
          echo "nested follows remove verified" > $out
        '';

    self-name =
      pkgs.runCommand "inputman-self-name-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          workdir=$(mktemp -d)/gigpkgs-fixture
          mkdir -p "$workdir"
          cd "$workdir"
          actual=$(inputman __self-name)
          test "$actual" = "gigpkgs-fixture"
          echo "self_name verified" > $out
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
