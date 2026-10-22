# gigpkgs inputMan: managed input
{ inputs, system }:
{
  giglab-dev = inputs.giglab-dev.packages.${system}.default;
}
