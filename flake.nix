{
  description = "Gig's nixpkgs overlay — super nixpkgs for the fleet";

  inputs = {
    # nixpkgs stable (source of truth for most packages)
    nixpkgs.follows = "nixpkgs-master";

    # nixos branches
    nixos-stable.follows = "nixos-2605";
    nixos-2605.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixpkgs branches
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/master";
    nixpkgs-master.follows = "nixpkgs-unstable";

    # Home Manager
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixos-2605";
    };

    # Pre-commit hooks
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fupdate.url = "github:gignsky/fupdate";

    gigvim.url = "github:gignsky/gigvim";

    roll-flow.url = "github:gignsky/roll-flow";

    claude-desktop.url = "github:k3d3/claude-desktop-linux-flake";
    claude-desktop.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      ...
    }@inputs:
    let
      # inherit (self) outputs;

      # Base nixpkgs channel for this branch, selected by the channel.nix marker.
      # gigos-* channel branches are CI-derived from the trunk by overwriting
      # ONLY that file, so every output below descends from one consistent base.
      channel = import ./channel.nix;
      base = inputs.${channel};

      lib = base.lib.extend (_final: prev: import ./lib { lib = prev; });
      system = "x86_64-linux";

      # Super nixpkgs: the selected base channel + gigpkgs overlays.
      pkgs = import base {
        inherit system;
        config = {
          allowUnfree = true;
        };
        overlays = builtins.attrValues (import ./overlays { inherit inputs; });
      };

      # News system — collect and expose news entries
      news = import ./news {
        inherit lib pkgs;
      };
    in
    {
      # Extended lib — all of nixpkgs.lib plus gigpkgs helpers (scanPaths, scanPathsNuShell).
      # Consumers: inputs.gigpkgs.lib.scanPaths
      inherit lib;

      # LegacyPackages — the branch's base channel extended with gigpkgs custom
      # packages (same `base` as `pkgs` above — unified via channel.nix). Use
      # inputs.gigpkgs.legacyPackages.${system} in consuming flakes as a drop-in
      # for nixpkgs.legacyPackages.${system} that includes gigpkgs packages.
      legacyPackages = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ] (s: base.legacyPackages.${s}.extend self.overlays.default);

      # Individual gigpkgs packages for direct access (e.g. `nix build .#locker`)
      packages.${system} = import ./pkgs {
        inherit pkgs inputs system;
        newsJson = news.json;
      };

      # Overlays for independent use in other flakes
      overlays = import ./overlays { inherit inputs; };

      # Expose news for consumers
      inherit news;

      # NixOS modules — auto-discovered from modules/nixos/ (+ inputMan-managed
      # aggregators under modules/nixos/inputs/).
      nixosModules = import ./modules/nixos { inherit lib inputs; };

      # Home Manager modules — auto-discovered from modules/home/ (+ inputMan-managed
      # aggregators under modules/home/inputs/).
      homeManagerModules = import ./modules/home { inherit lib inputs; };

      # Pre-commit hooks for this repo
      pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
        src = ./.;
        hooks = {
          nixfmt = {
            enable = true;
            excludes = [
              ".*/hardware-configuration\\.nix$"
            ];
          };
          statix = {
            enable = true;
          };
          deadnix = {
            enable = true;
            excludes = [ ];
          };
          shellcheck = {
            enable = true;
            excludes = [ ];
          };
          markdownlint = {
            enable = false;
          };
          yamllint = {
            enable = true;
            excludes = [
              ".github/workflows/flake-check.yml"
            ];
          };
          end-of-file-fixer = {
            enable = true;
          };
        };
      };

      # Checks — build each package to verify it evaluates and builds
      checks.${system} = import ./checks {
        inherit
          self
          pkgs
          lib
          inputs
          ;
      };

      # Dev shell for working on gigpkgs. Single-output packages from every
      # installed input (files under ./pkgs/inputs/ exposing
      # `packages.<system>.default`) are auto-included via
      # devShellPackages.nix; multi-variant inputs must be added by name below.
      devShells.${system}.default = pkgs.mkShell {
        NIX_CONFIG = "extra-experimental-features = nix-command flakes";

        nativeBuildInputs =
          builtins.attrValues {
            inherit (pkgs)
              git
              pre-commit
              lolcat
              nixfmt
              nil
              just
              lazygit
              statix
              deadnix
              nix
              fzf
              quick-results
              upjust
              locker
              ripgrep
              inputman
              upignore
              ;
          }
          ++ [ self.packages.${system}.gignews ];
        # ++ (import ./pkgs/inputs/devShellPackages.nix {
        #   inherit inputs system lib;
        # });
        shellHook = ''
          ${self.pre-commit-check.shellHook}

          echo "Welcome to the gigpkgs devShell" | ${pkgs.lolcat}/bin/lolcat
        '';
      };

      # Nix formatter
      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
