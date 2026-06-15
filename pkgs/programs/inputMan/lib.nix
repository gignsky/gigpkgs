# Pure Nix template generator — no nixpkgs dependency, safe to import via nix eval.
# ds produces a literal "${" in generated output (Nix's string-interpolation escape).
let
  ds = "$" + "{";
in
{
  mkInputFile =
    { name, packages }:
    let
      mkLine =
        pkg:
        let
          alias = if pkg == "default" then name else "${name}-${pkg}";
        in
        "  ${alias} = inputs.${name}.packages.${ds}system}.${pkg};";
      lines = builtins.concatStringsSep "\n" (builtins.map mkLine packages);
    in
    "# gigpkgs inputMan: managed input\n{ inputs, system }:\n{\n${lines}\n}\n";
}
