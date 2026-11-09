# gig's NixOS / home-manager rebuild scripts, moved here from the dotfiles repo
# so other tools (roll-flow's `n` menu, any flake) can depend on them.
#
# Named `gig-*` on purpose: this repo is the fleet's `nixpkgs`, and a package
# called `nixos-rebuild` would shadow the real `pkgs.nixos-rebuild` for every
# consumer — the script itself calls `sudo nixos-rebuild` and would recurse.
#
# The scripts still work against the flake in the *current directory* (they
# build `.#<host>` and `git commit -a` the result), so they are run from inside
# the dotfiles checkout, exactly as before.
#
# Only `host-detection-lib.sh` ships beside them. The scripts look for it in
# `~/.dotfiles/scripts/` first and beside themselves second, so this is a
# fallback, never an override. `commit-enhance-lib.sh` is deliberately NOT
# shipped: when the scripts find it they write `auto(system): rebuild ...`
# subjects instead of `<host>: generation N (<mode>)` / `<user>@<host>: ...`,
# which is the shape roll-flow's `build` column reads. It was never found when
# packaged from the dotfiles repo either (a single store file has no
# neighbours), so leaving it out keeps the commits exactly as they are today.

{ pkgs }:
let
  src = builtins.path {
    path = ./.;
    name = "gig-rebuild-scripts-src";
    filter = path: _type: pkgs.lib.hasSuffix ".sh" path;
  };

  makeRebuildScript =
    {
      name,
      script,
      dependencies,
      description,
    }:
    pkgs.writeShellScriptBin name ''
      # Make dependencies available in PATH, ahead of the caller's own.
      export PATH="${pkgs.lib.makeBinPath dependencies}:$PATH"

      # Exec the script from its own store directory, so its
      # `$(dirname "$0")` lookup finds host-detection-lib.sh beside it. The
      # working directory is left alone: the scripts build the flake in it.
      exec ${pkgs.bash}/bin/bash "${src}/${script}" "$@"
    ''
    // {
      meta = {
        inherit description;
        mainProgram = name;
        maintainers = [ ];
      };
      passthru.tests.syntax = pkgs.runCommand "${name}-syntax" { } ''
        ${pkgs.bash}/bin/bash -n "${src}/${script}"
        ${pkgs.bash}/bin/bash -n "${src}/host-detection-lib.sh"
        echo "syntax ok" > $out
      '';
    };
in
{
  gig-nixos-rebuild = makeRebuildScript {
    name = "gig-nixos-rebuild";
    script = "nixos-rebuild.sh";
    dependencies = with pkgs; [
      bash
      nix
      # nixos-rebuild itself comes from the running system, not from here
      # (the system's own version is the one that matches it).
      hostname
      util-linux # `script`, used to keep Nix's live build-progress bar when teeing output
    ];
    description = "Rebuilds this machine's NixOS configuration from the flake in the current directory, committing a generation marker";
  };

  gig-home-switch = makeRebuildScript {
    name = "gig-home-switch";
    script = "home-switch.sh";
    dependencies = with pkgs; [
      bash
      nix
      home-manager
      hostname
      util-linux # `script`, used to keep Nix's live build-progress bar when teeing output
    ];
    description = "Rebuilds this machine's home-manager configuration from the flake in the current directory, committing a generation marker";
  };
}
