# Evaluation checks for `gigpkgs.containers.fromInputs`: a published container
# spec (faked here, so no input is needed) becomes a podman service with the
# host's additions applied, and an unknown name fails with a clear assertion.
{
  lib,
  pkgs,
  inputs,
  self,
  ...
}:
let
  evalConfig = import (inputs.${import ../channel.nix} + "/nixos/lib/eval-config.nix");

  fakeSpec = {
    service = {
      image = "demo:1.0.0";
      imageFile = pkgs.writeText "demo-image" "";
      autoStart = true;
      ports = [ "127.0.0.1:8800:8800/tcp" ];
      environment.TZ = "UTC";
      extraOptions = [ ];
    };
  };

  nixos =
    extra:
    evalConfig {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.containers
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "ext4";
          };
          system.stateVersion = "25.05";
          gigpkgs.containers.enable = true;
        }
        extra
      ];
    };

  good = nixos {
    gigpkgs.containers.available = lib.mkForce { demo = fakeSpec; };
    gigpkgs.containers.fromInputs.demo = {
      enable = true;
      environmentFiles = [ "/run/secrets/demo-env" ];
      volumes = [ "/var/lib/demo:/data" ];
      overrides.ports = [ "127.0.0.1:9000:8800/tcp" ];
    };
  };
  container = good.config.virtualisation.oci-containers.containers.demo;

  bad = nixos {
    gigpkgs.containers.available = lib.mkForce { };
    gigpkgs.containers.fromInputs.nope.enable = true;
  };
  failed = map (a: a.message) (lib.filter (a: !a.assertion) bad.config.assertions);

  verdict =
    if container.image != "demo:1.0.0" then
      throw "fromInputs: image not taken from the published spec"
    else if container.ports != [ "127.0.0.1:9000:8800/tcp" ] then
      throw "fromInputs: overrides did not replace ports"
    else if container.volumes != [ "/var/lib/demo:/data" ] then
      throw "fromInputs: volumes not appended"
    else if container.environmentFiles != [ "/run/secrets/demo-env" ] then
      throw "fromInputs: environmentFiles not appended"
    else if !(good.config.systemd.services ? podman-demo) then
      throw "fromInputs: no podman-demo unit generated"
    else if failed == [ ] then
      throw "fromInputs: an unknown container did not fail an assertion"
    else
      "ok";
in
{
  containers-from-inputs = pkgs.runCommand "containers-from-inputs" { } "echo ${verdict} > $out";
}
