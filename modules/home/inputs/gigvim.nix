# gigpkgs inputMan: managed homeManagerModules aggregator
{ inputs }:
{
  # gigvim renamed `homeManagerModules` -> `homeModules` (gigvim@7a7de45);
  # accept either so older/newer gigvim pins both evaluate.
  gigvim = inputs.gigvim.homeModules.default or inputs.gigvim.homeManagerModules.default;
}
