# gigpkgs inputMan: managed input
{ inputs, system }:
{
  gigvim = inputs.gigvim.packages.${system}.default;
  gigvim-full = inputs.gigvim.packages.${system}.full;
  gigvim-gigvim = inputs.gigvim.packages.${system}.gigvim;
  gigvim-mini = inputs.gigvim.packages.${system}.mini;
  gigvim-minimal = inputs.gigvim.packages.${system}.minimal;
}