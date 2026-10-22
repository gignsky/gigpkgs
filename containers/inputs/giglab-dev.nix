# gigpkgs inputMan: managed containers aggregator
{ inputs, system }:
{
  giglab = inputs.giglab-dev.containers.${system}.giglab;
}
