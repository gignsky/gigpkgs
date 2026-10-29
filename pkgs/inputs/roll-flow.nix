# gigpkgs inputMan: managed input
{ inputs, system }:
{
  roll-flow = inputs.roll-flow.packages.${system}.default;
  "roll-flow-0.2.5" = inputs.roll-flow-0_2_5.packages.${system}.default;
  "roll-flow-0.2.6-dev" = inputs.roll-flow-0_2_6-dev.packages.${system}.default;
  "roll-flow-0.2.7" = inputs.roll-flow-0_2_7.packages.${system}.default;
  "roll-flow-0.2.8" = inputs.roll-flow-0_2_8.packages.${system}.default;
  "roll-flow-0.2.9" = inputs.roll-flow-0_2_9.packages.${system}.default;
  "roll-flow-0.2.9-dev" = inputs.roll-flow-0_2_9-dev.packages.${system}.default;
  "roll-flow-0.2.10" = inputs.roll-flow-0_2_10.packages.${system}.default;
  "roll-flow-0.2.11" = inputs.roll-flow-0_2_11.packages.${system}.default;
  "roll-flow-0.2.12-dev" = inputs.roll-flow-0_2_12-dev.packages.${system}.default;
  "roll-flow-0.2.13" = inputs.roll-flow-0_2_13.packages.${system}.default;
  "roll-flow-0.2.14" = inputs.roll-flow-0_2_14.packages.${system}.default;
  "roll-flow-0.2.15" = inputs.roll-flow-0_2_15.packages.${system}.default;
}
