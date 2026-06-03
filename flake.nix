{
  description = "Gig's nixpkgs overlay — super nixpkgs for the fleet";

  inputs = {
    # nixpkgs stable (source of truth for most packages)
    nixpkgs.follows = "nixos-unstable";

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
      inputs.nixpkgs.follows = "nixos-stable";
    };

    # Pre-commit hooks
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      # nixpkgs-unstable,
      ...
    }@inputs:
    let
      # inherit (self) outputs;
      lib = nixpkgs.lib.extend (_final: prev: import ./lib { lib = prev; });
      system = "x86_64-linux";

      # Build the super nixpkgs set:
      # nixpkgs stable + gigpkgs overlays (additions, unstable-packages)
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
        overlays = builtins.attrValues (import ./overlays { inherit inputs; });
      };
    in
    {
      # Extended lib — all of nixpkgs.lib plus gigpkgs helpers (scanPaths, scanPathsNuShell).
      # Consumers: inputs.gigpkgs.lib.scanPaths
      inherit lib;

      # LegacyPackages — nixos-stable extended with gigpkgs custom packages.
      # Use inputs.gigpkgs.legacyPackages.${system} in consuming flakes as a
      # drop-in for nixpkgs.legacyPackages.${system} that includes gigpkgs packages.
      legacyPackages = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ] (s: inputs.nixos-stable.legacyPackages.${s}.extend self.overlays.default);

      # Individual gigpkgs packages for direct access (e.g. `nix build .#locker`)
      packages.${system} = import ./pkgs { inherit pkgs; };

      # Overlays for independent use in other flakes
      overlays = import ./overlays { inherit inputs; };

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
            enable = false;
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
          ;
      };

      # Dev shell for working on gigpkgs
      devShells.${system}.default = pkgs.mkShell {
        NIX_CONFIG = "extra-experimental-features = nix-command flakes";

        nativeBuildInputs = builtins.attrValues {
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
            upignore
            ;
        };
        shellHook = ''
          ${self.pre-commit-check.shellHook}

          echo "Welcome to the gigpkgs devShell" | ${pkgs.lolcat}/bin/lolcat
        '';
      };

      # Nix formatter
      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
