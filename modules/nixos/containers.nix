# Generic, reusable container engine for the fleet.
#
# Auto-discovered by modules/nixos/default.nix and exposed as
# `gigpkgs.nixosModules.containers`. This is the "engine" half of the hybrid
# container split (dotfiles#14): it sets up the OCI runtime and provides a
# uniform way to declare containers that run either **as a service** (systemd,
# via virtualisation.oci-containers) or **adhoc** (backend CLI + generated
# images). Host-specific container payloads live in the consuming repo, not here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.gigpkgs.containers;
in
{
  options.gigpkgs.containers = {
    enable = lib.mkEnableOption "the gigpkgs container engine (OCI runtime + service/adhoc helpers)";

    backend = lib.mkOption {
      type = lib.types.enum [
        "podman"
        "docker"
      ];
      default = "podman";
      description = "OCI container backend used for both service and adhoc containers.";
    };

    adhoc.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the backend CLI + compose so containers can be run adhoc
        (e.g. `podman run ...`, `nix run` of a generated image) in addition to
        the declared `services`.
      '';
    };

    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          myapp = {
            image = "docker.io/library/nginx:latest";
            ports = [ "8080:80" ];
          };
        }
      '';
      description = ''
        Declarative "run as a service" containers. Each entry is an
        `virtualisation.oci-containers.containers.<name>` definition and is
        started via systemd. `autoStart` defaults to true; set it explicitly to
        override.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        virtualisation.oci-containers.backend = cfg.backend;
        # Pass the declared services through, defaulting autoStart to true.
        virtualisation.oci-containers.containers = builtins.mapAttrs (
          _name: container: { autoStart = lib.mkDefault true; } // container
        ) cfg.services;
      }

      (lib.mkIf (cfg.backend == "podman") {
        virtualisation.podman = {
          enable = true;
          dockerCompat = lib.mkDefault true;
        };
      })

      (lib.mkIf (cfg.backend == "docker") {
        virtualisation.docker.enable = true;
      })

      (lib.mkIf cfg.adhoc.enable {
        environment.systemPackages =
          if cfg.backend == "podman" then
            [
              pkgs.podman
              pkgs.podman-compose
            ]
          else
            [
              pkgs.docker
              pkgs.docker-compose
            ];
      })
    ]
  );
}
