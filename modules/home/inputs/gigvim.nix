# gigpkgs inputMan: managed homeModules aggregator
{ inputs }:
{
  default = inputs.gigvim.homeModules.default;
  gigvim = inputs.gigvim.homeModules.gigvim;
}
