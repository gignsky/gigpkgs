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
      inputs.nixpkgs.follows = "nixos-2605";
    };

    # Pre-commit hooks
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fupdate.url = "github:gignsky/fupdate";

    gigvim = {
      url = "github:gignsky/gigvim";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        home-manager.follows = "home-manager";
      };
    };

    roll-flow = {
      url = "github:gignsky/roll-flow/main";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    claude-desktop.url = "github:heytcass/claude-desktop-linux-flake";
    claude-desktop.inputs.nixpkgs.follows = "nixpkgs";

    roll-flow-0_2_5 = {
      url = "github:gignsky/roll-flow/15683995d37e93f90e991303ccfa111f37fe51fb";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_6-dev = {
      url = "github:gignsky/roll-flow/ec731b2deb8c5f5d9f518563e548e08f4fd593aa";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_7 = {
      url = "github:gignsky/roll-flow/7d42a7f97bf9404e17a2b52580fcbd3bf3f9513c";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_8 = {
      url = "github:gignsky/roll-flow/f64328f0b40819617b3933f6f15f88ff12f3fa1c";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_9 = {
      url = "github:gignsky/roll-flow/035f841edfcf2ee30e9554364ba3584226d496be";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_9-dev = {
      url = "github:gignsky/roll-flow/b9475a7a4401e45be3b1649df1d63d2e3240b376";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_10 = {
      url = "github:gignsky/roll-flow/16b516238a9d4f041c02ce6f049665332bd341bb";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_11 = {
      url = "github:gignsky/roll-flow/ef98701c006cf8693038485a6be227ad1d501fe8";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_12-dev = {
      url = "github:gignsky/roll-flow/8fb70226565442e2326ede9d7c0c658764c34045";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_13 = {
      url = "github:gignsky/roll-flow/9985941dfb459ddfb8f5987e1310650c6878423a";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    giglab-dev = {
      url = "github:gignsky/giglab.dev";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    roll-flow-0_2_14 = {
      url = "github:gignsky/roll-flow/c41971dca4693053a71881a30f84a00615194e79";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_15 = {
      url = "github:gignsky/roll-flow/21c28318eaba43b36d26064a98eade8cb0797548";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };

    roll-flow-0_2_16 = {
      url = "github:gignsky/roll-flow/d11d0e0563be8e6c556eb40b21f9598b12f266ad";
      inputs = {
        nixpkgs.follows = "nixpkgs-unstable";
        pre-commit-hooks.follows = "pre-commit-hooks";
      };
    };
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

      gigpkgs = self.packages.${system};
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

      # Containers published by inputs (inputMan-managed aggregators under
      # containers/inputs/); see gigpkgs.containers.fromInputs.
      containers.${system} = import ./containers { inherit inputs system; };

      # NixOS modules — auto-discovered from modules/nixos/ (+ inputMan-managed
      # aggregators under modules/nixos/inputs/).
      nixosModules =
        let
          modules = import ./modules/nixos { inherit lib inputs; };
        in
        modules
        // {
          # The engine module needs to see this flake's containers; auto-discovery
          # only imports paths, so hand them in here.
          containers =
            { pkgs, ... }:
            {
              imports = [ modules.containers ];
              gigpkgs.containers.available = self.containers.${pkgs.stdenv.hostPlatform.system} or { };
            };
        };

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
              # Long `run:`/printf shell lines can't be wrapped to 80 cols.
              ".github/workflows/channels.yml"
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
          ++ [
            gigpkgs.gignews
            gigpkgs.roll-flow
          ];
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
