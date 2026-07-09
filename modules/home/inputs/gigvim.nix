# gigpkgs inputMan: managed homeModules aggregator
{ inputs }:
{
  default = inputs.gigvim.homeManagerModules.default;
  gigvim = inputs.gigvim.homeManagerModules.gigvim;
}
