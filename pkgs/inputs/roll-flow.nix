# gigpkgs inputMan: managed input
{ inputs, system }:
{
  roll-flow = inputs.roll-flow.packages.${system}.default;
  "roll-flow-0.2.5" = inputs.roll-flow-0_2_5.packages.${system}.default;
  "roll-flow-0.2.6-dev" = inputs.roll-flow-0_2_6-dev.packages.${system}.default;
}
