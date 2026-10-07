# gigpkgs inputMan: managed input
{ inputs, system }:
{
  roll-flow = inputs.roll-flow.packages.${system}.default;
  "roll-flow-0.2.5" = inputs.roll-flow-0_2_5.packages.${system}.default;
  "roll-flow-0.2.6-dev" = inputs.roll-flow-0_2_6-dev.packages.${system}.default;
  "roll-flow-0.2.7" = inputs.roll-flow-0_2_7.packages.${system}.default;
  "roll-flow-0.2.8" = inputs.roll-flow-0_2_8.packages.${system}.default;
  "roll-flow-0.2.9" = inputs.roll-flow-0_2_9.packages.${system}.default;
}
