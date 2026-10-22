{
  lib,
  pkgs,
  inputs,
  ...
}:
let
  packageBuilds = lib.mapAttrs' (name: pkg: {
    name = "build-${name}";
    value = pkg;
  }) (import ../pkgs { inherit pkgs inputs; });

  # gigpkgs must never (transitively) depend on itself: an input whose own
  # `nixpkgs` is github:gignsky/gigpkgs drags in an older copy of this repo
  # plus a second nixpkgs. Fix with `inputman doctor --fix`.
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  isGigpkgs =
    node: (node.original.repo or "") == "gigpkgs" && (node.original.owner or "") == "gignsky";
  circular = lib.attrNames (lib.filterAttrs (_: isGigpkgs) lock.nodes);
in
packageBuilds
// {
  no-circular-gigpkgs = pkgs.runCommand "no-circular-gigpkgs" { } (
    if circular == [ ] then
      "touch $out"
    else
      ''
        echo "flake.lock contains gigpkgs itself as an input (${lib.concatStringsSep ", " circular})." >&2
        echo "Run 'inputman doctor --fix' to add the follows that break the loop." >&2
        exit 1
      ''
  );
}
