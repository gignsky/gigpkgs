{ pkgs }:
let
  pkg = pkgs.stdenv.mkDerivation {
    pname = "inputman";
    version = "0.4.0";

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
            pkgs.fzf
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
          grep -q -- "pin <name> <ref>" help_output
          grep -q -- "versions <name>" help_output
          grep -q -- "branch <name>" help_output
          grep -q -- "--follows" help_output
          grep -q -- "--packages, -p" help_output
          grep -q -- "--no-info" help_output
          grep -q -- "--no-branch" help_output
          grep -q -- "--no-modules" help_output
          grep -q -- "--no-commit" help_output
          grep -q "doctor" help_output
          grep -q -- "--no-auto-follows" help_output

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

    version-changes =
      pkgs.runCommand "inputman-version-changes-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
          ];
        }
        ''
          set -e
          before=$'roll-flow=0.2.3\ngigvim=1.0.0'
          after=$'roll-flow=0.2.4\ngigvim=1.0.0\nroll-flow-cli=0.1.0'

          inputman __version-changes "$before" "$after" > out

          grep -q "^roll-flow 0.2.3 -> 0.2.4$" out
          grep -q "^roll-flow-cli 0.1.0 (new)$" out

          # Unchanged packages must not appear in the diff.
          if grep -q "gigvim" out; then
            echo "unchanged package leaked into the diff"; cat out; exit 1
          fi

          echo "version_changes verified" > $out
        '';

    news-entry-version-diff =
      pkgs.runCommand "inputman-news-entry-version-diff-test"
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
          mkdir -p news/entries

          details=$'Revision: f9d75fc -> a1b2c3d\nUpstream date: 2026-01-01 -> 2026-02-02\nVersions:\n  roll-flow 0.2.3 -> 0.2.4'
          inputman __write-news-entry update roll-flow "$details" " (0.2.3 -> 0.2.4)"

          entry=$(echo news/entries/*-inputman-update-roll-flow.nix)
          test -f "$entry"

          grep -q "Updated flake input 'roll-flow' (0.2.3 -> 0.2.4)" "$entry"
          grep -q "Revision: f9d75fc -> a1b2c3d" "$entry"
          grep -q "Upstream date: 2026-01-01 -> 2026-02-02" "$entry"
          grep -q "roll-flow 0.2.3 -> 0.2.4" "$entry"
          grep -q "num = 1;" "$entry"

          echo "news entry version diff verified" > $out
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

          grep -q 'gigvim = {' flake.nix
          grep -q 'url = "github:gignsky/gigvim";' flake.nix
          grep -q 'inputs.nixpkgs.follows = "nixpkgs";' flake.nix
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
          grep -q 'inputs.gigpkgs.inputs.nixpkgs.follows = "nixpkgs-master";' flake.nix

          # Dot-separated nested follows
          inputman __patch-flake-add other github:foo/other a.b.c=target
          grep -q 'inputs.a.inputs.b.inputs.c.follows = "target";' flake.nix

          # Empty follows (bare -f)
          inputman __patch-flake-add self-follow github:foo/self gigpkgs=
          grep -q 'inputs.gigpkgs.follows = "";' flake.nix

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
          command -v fzf > /dev/null
          echo "Runtime dependencies verified" > $out
        '';

    patch-flake-set-url =
      pkgs.runCommand "inputman-patch-flake-set-url-test"
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
                  roll-flow.url = "github:gignsky/roll-flow";
                  roll-flow.inputs.nixpkgs.follows = "nixpkgs";
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          inputman __patch-flake-set-url roll-flow github:gignsky/roll-flow/some-branch

          grep -q 'url = "github:gignsky/roll-flow/some-branch";' flake.nix
          grep -q 'inputs.nixpkgs.follows = "nixpkgs";' flake.nix
          grep -q 'nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";' flake.nix

          if inputman __patch-flake-set-url not-an-input github:foo/bar > output 2>&1; then
            echo "Setting url for a missing input should fail"
            cat output
            exit 1
          fi
          grep -q "could not find" output

          echo "patch_flake_set_url verified" > $out
        '';

    gigpkgs-channel-input =
      pkgs.runCommand "inputman-gigpkgs-channel-input-test"
        {
          buildInputs = [ pkg ];
        }
        ''
          set -e
          test "$(inputman __gigpkgs-channel-input gigpkgs-unstable)" = "nixpkgs-unstable"
          test "$(inputman __gigpkgs-channel-input gigos-unstable)" = "nixos-unstable"
          test "$(inputman __gigpkgs-channel-input gigos-2605)" = "nixos-2605"
          test "$(inputman __gigpkgs-channel-input master)" = "nixpkgs"
          test "$(inputman __gigpkgs-channel-input "")" = "nixpkgs"
          echo "gigpkgs_channel_input verified" > $out
        '';

    detect-circular-follows =
      pkgs.runCommand "inputman-detect-circular-follows-test"
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

          # A repo lock: `foo` tracks gigpkgs@gigos-2605 and follows through it;
          # `bar` tracks gigpkgs on its default branch; `clean` does not.
          cat > repo.lock <<'LOCK'
          {
            "nodes": {
              "root": { "inputs": { "foo": "foo", "bar": "bar", "clean": "clean", "nixpkgs": "nixpkgs" } },
              "nixpkgs": { "original": { "owner": "NixOS", "repo": "nixpkgs", "type": "github" } },
              "foo": { "inputs": { "nixpkgs": "gp_a", "pre-commit-hooks": ["foo", "nixpkgs", "pre-commit-hooks"], "utils": "utils" } },
              "bar": { "inputs": { "nixpkgs": "gp_b" } },
              "clean": { "inputs": { "nixpkgs": ["nixpkgs"], "utils": "utils" } },
              "gp_a": { "original": { "owner": "gignsky", "repo": "gigpkgs", "ref": "gigos-2605", "type": "github" } },
              "gp_b": { "original": { "owner": "gignsky", "repo": "gigpkgs", "type": "github" } },
              "utils": { "original": { "owner": "numtide", "repo": "flake-utils", "type": "github" } }
            },
            "root": "root",
            "version": 7
          }
          LOCK

          inputman __detect-circular-follows repo.lock foo foo > foo.out
          grep -qx "nixpkgs=nixos-2605" foo.out
          grep -qx "pre-commit-hooks=pre-commit-hooks" foo.out
          test "$(wc -l < foo.out)" = 2

          inputman __detect-circular-follows repo.lock bar bar > bar.out
          grep -qx "nixpkgs=nixpkgs" bar.out
          test "$(wc -l < bar.out)" = 1

          inputman __detect-circular-follows repo.lock clean clean > clean.out
          test ! -s clean.out

          # A sub-lock (as `nix flake metadata --json` reports it): the
          # inspected node is the lock's own root, so follows paths carry no
          # input-name prefix.
          cat > sub.lock <<'LOCK'
          {
            "nodes": {
              "root": { "inputs": { "nixpkgs": "gp", "pre-commit-hooks": ["nixpkgs", "pre-commit-hooks"] } },
              "gp": { "original": { "owner": "gignsky", "repo": "gigpkgs", "ref": "gigpkgs-unstable", "type": "github" } }
            },
            "root": "root",
            "version": 7
          }
          LOCK
          inputman __detect-circular-follows sub.lock root > sub.out
          grep -qx "nixpkgs=nixpkgs-unstable" sub.out
          grep -qx "pre-commit-hooks=pre-commit-hooks" sub.out

          echo "detect_circular_follows verified" > $out
        '';

    patch-flake-follows =
      pkgs.runCommand "inputman-patch-flake-follows-test"
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
                  roll-flow.url = "github:gignsky/roll-flow";
                  other.url = "github:foo/other";
              };
              outputs = { self, ... }: { };
          }
          FLAKE

          inputman __patch-flake-follows roll-flow nixpkgs=nixpkgs-unstable pre-commit-hooks=pre-commit-hooks

          # Two follows: one `roll-flow` block with a single `inputs` set (no
          # repeated keys for statix), and the other inputs untouched.
          grep -q 'roll-flow = {' flake.nix
          grep -q 'nixpkgs.follows = "nixpkgs-unstable";' flake.nix
          grep -q 'pre-commit-hooks.follows = "pre-commit-hooks";' flake.nix
          test "$(grep -c 'inputs = {' flake.nix)" = 2   # the outer block + roll-flow's
          grep -q 'other.url = "github:foo/other";' flake.nix

          # Idempotent: a key that is already declared is not duplicated.
          inputman __patch-flake-follows roll-flow nixpkgs=nixpkgs-unstable
          test "$(grep -c 'nixpkgs.follows = "nixpkgs-unstable"' flake.nix)" = 1

          if inputman __patch-flake-follows missing nixpkgs=nixpkgs > output 2>&1; then
            echo "patching a missing input should fail"; cat output; exit 1
          fi
          grep -q "could not find" output

          echo "patch_flake_follows verified" > $out
        '';

    flake-edits-pass-hooks =
      pkgs.runCommand "inputman-flake-edits-pass-hooks-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
            pkgs.nixfmt
            pkgs.statix
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

              # about gone
              gone.url = "github:x/gone";
              gone.inputs.nixpkgs.follows = "nixpkgs";

              claude-desktop.url = "github:heytcass/claude-desktop-linux-flake";
              claude-desktop.inputs.nixpkgs.follows = "nixpkgs";
              claude-desktop.inputs.flake-utils.follows = "nixpkgs";
            };
            outputs = { self, ... }: { };
          }
          FLAKE

          check() {
            nixfmt --check flake.nix
            statix check flake.nix
          }

          # Every editing operation must leave flake.nix passing the nixfmt and
          # statix pre-commit hooks (no repeated `name.` keys, `};` indented).
          inputman __patch-flake-tidy
          grep -q 'claude-desktop = {' flake.nix
          check

          inputman __patch-flake-add gigvim github:gignsky/gigvim nixpkgs=nixpkgs-unstable home-manager=home-manager
          grep -q 'gigvim = {' flake.nix
          test "$(grep -c 'inputs = {' flake.nix)" = 3   # outer + claude-desktop + gigvim
          check

          inputman __patch-flake-follows gigvim extra=extra
          grep -q 'extra.follows = "extra";' flake.nix
          check

          inputman __patch-flake-set-url gigvim github:gignsky/gigvim/other
          grep -q 'url = "github:gignsky/gigvim/other";' flake.nix
          grep -q 'home-manager.follows = "home-manager";' flake.nix
          check

          inputman __patch-flake-remove gone
          if grep -q 'gone' flake.nix; then
            echo "gone (and its comment) should be removed"; cat flake.nix; exit 1
          fi
          check

          echo "flake edits pass the pre-commit hooks" > $out
        '';

    generated-aggregator-passes-nixfmt =
      pkgs.runCommand "inputman-generated-aggregator-nixfmt-test"
        {
          buildInputs = [
            pkg
            pkgs.gnugrep
            pkgs.nixfmt
          ];
        }
        ''
          set -e
          workdir=$(mktemp -d)
          cd "$workdir"

          # A long package name pushes its line past 100 columns, which nixfmt
          # wraps; the generator must emit the wrapped form itself.
          inputman __generate-input-file claude-desktop \
            claude-desktop=claude-desktop \
            claude-desktop-with-fhs=claude-desktop-claude-desktop-with-fhs > out.nix
          grep -q '^  claude-desktop-claude-desktop-with-fhs =$' out.nix
          nixfmt --check out.nix

          echo "generated aggregator passes nixfmt" > $out
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
