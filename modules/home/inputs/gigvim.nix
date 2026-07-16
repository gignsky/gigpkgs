# gigpkgs inputMan: managed homeManagerModules aggregator
{ inputs }:
{
  default = inputs.gigvim.homeManagerModules.default;
  gigvim = inputs.gigvim.homeManagerModules.gigvim;
}
