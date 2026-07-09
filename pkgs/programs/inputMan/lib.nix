# Pure Nix template generators — no nixpkgs dependency, safe to import via nix eval.
# `ds` produces a literal "${" in generated output (Nix's string-interpolation escape).
let
  ds = "$" + "{";
in
{
  # Build a `pkgs/inputs/<name>.nix` aggregator.
  # `packages` may be either:
  #   - a list of package names (legacy; alias inferred: default → name, else name-<pkg>)
  #   - an attrset of { <pkg> = <alias>; } — same shape inputMan writes today.
  mkInputFile =
    {
      name,
      packages,
    }:
    let
      pairs =
        if builtins.isList packages then
          builtins.map (p: {
            pkg = p;
            alias = if p == "default" then name else "${name}-${p}";
          }) packages
        else
          builtins.map (pkg: {
            inherit pkg;
            alias = packages.${pkg};
          }) (builtins.attrNames packages);
      mkLine = entry: "  ${entry.alias} = inputs.${name}.packages.${ds}system}.${entry.pkg};";
      lines = builtins.concatStringsSep "\n" (builtins.map mkLine pairs);
    in
    "# gigpkgs inputMan: managed input\n{ inputs, system }:\n{\n${lines}\n}\n";

  # Build a `modules/<home|nixos>/inputs/<name>.nix` aggregator.
  # `kind` is either "home" or "nixos".
  # `modules` is an attrset of { <moduleName> = <alias>; }.
  mkModuleFile =
    {
      name,
      kind,
      modules,
    }:
    let
      attr = if kind == "home" then "homeModules" else "nixosModules";
      mkLine = mod: "  ${modules.${mod}} = inputs.${name}.${attr}.${mod};";
      lines = builtins.concatStringsSep "\n" (builtins.map mkLine (builtins.attrNames modules));
    in
    "# gigpkgs inputMan: managed ${attr} aggregator\n{ inputs }:\n{\n${lines}\n}\n";
}
