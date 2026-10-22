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
  enabledFromInputs = lib.filterAttrs (_: c: c.enable) cfg.fromInputs;

  # The published `service` attrset, with the host's additions and overrides.
  fromInputService =
    name: c:
    let
      spec = cfg.available.${name}.service;
      merged = spec // c.overrides;
    in
    merged
    // lib.optionalAttrs (c.environmentFiles != [ ]) {
      environmentFiles = (merged.environmentFiles or [ ]) ++ c.environmentFiles;
    }
    // lib.optionalAttrs (c.volumes != [ ]) {
      volumes = (merged.volumes or [ ]) ++ c.volumes;
    };
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

    available = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      internal = true;
      description = ''
        Container specs published by gigpkgs' flake inputs, by name (the flake's
        `containers.<system>`). Filled in by `gigpkgs.nixosModules.containers`;
        not meant to be set by hand.
      '';
    };

    fromInputs = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        {
          giglab = {
            enable = true;
            environmentFiles = [ config.sops.secrets."giglab-env".path ];
            volumes = [ "/var/lib/giglab:/data" ];
          };
        }
      '';
      description = ''
        Containers that a gigpkgs flake input publishes (found under
        `containers.<system>`, managed by inputMan), run as services. The
        input supplies the image and the host-agnostic spec; the host adds what
        only it knows (secret env files, volumes) or overrides it outright.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "this input-published container";
            overrides = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
              description = "Attributes replacing the published spec's (e.g. `ports`, `environment`).";
            };
            environmentFiles = lib.mkOption {
              type = lib.types.listOf (lib.types.either lib.types.path lib.types.str);
              default = [ ];
              description = "Env files appended to the spec's own (host paths, e.g. sops secrets).";
            };
            volumes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Volumes appended to the spec's own, as `host:container`.";
            };
          };
        }
      );
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
        assertions = lib.mapAttrsToList (name: _: {
          assertion = cfg.available ? ${name};
          message = "gigpkgs.containers.fromInputs.${name}: no such container in gigpkgs (available: ${lib.concatStringsSep ", " (lib.attrNames cfg.available)}). Install it with `inputman install`.";
        }) enabledFromInputs;

        gigpkgs.containers.services = lib.mapAttrs fromInputService (
          lib.filterAttrs (name: _: cfg.available ? ${name}) enabledFromInputs
        );
      }

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
