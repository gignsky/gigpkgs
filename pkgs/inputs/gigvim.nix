# gigpkgs inputMan: managed input
{ inputs, system }:
{
  gigvim = inputs.gigvim.packages.${system}.default;
}