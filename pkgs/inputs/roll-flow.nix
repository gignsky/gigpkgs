# gigpkgs inputMan: managed input
{ inputs, system }:
{
  roll-flow = inputs.roll-flow.packages.${system}.default;
  roll-flow-roll-flow = inputs.roll-flow.packages.${system}.roll-flow;
}