{
  description = "Gig's nixpkgs overlay — super nixpkgs for the fleet";

  inputs = {
    # nixpkgs stable (source of truth for most packages)
    nixpkgs.follows = "nixpkgs-stable";
    nixpkgs-stable.follows = "nixpkgs-2605";
    nixpkgs-2605.url = "github:NixOS/nixpkgs/nixos-26.05";
    # nixpkgs unstable (accessible as pkgs.unstable)
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/master";

    # Home Manager
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
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
      inherit (nixpkgs) lib;
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
      # Re-export nixpkgs lib so consumers can use gigpkgs.lib.nixosSystem, etc.
      inherit (nixpkgs) lib;

      # LegacyPackages — the full nixpkgs set with gigpkgs overlays applied.
      # Use this as a drop-in replacement for nixpkgs.legacyPackages.${system}
      # in consuming flakes (e.g. dotfiles).
      legacyPackages.${system} = pkgs;

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
