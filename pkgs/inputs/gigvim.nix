# gigpkgs inputMan: managed input
{ inputs, system }:
{
  gigvim = inputs.gigvim.packages.${system}.default;
  gigvim-full = inputs.gigvim.packages.${system}.full;
  gigvim-mini = inputs.gigvim.packages.${system}.mini;
  gigvim-minimal = inputs.gigvim.packages.${system}.minimal;
  gigvim-differ = inputs.gigvim.packages.${system}.differ;
  gigvim-gigvim-differ = inputs.gigvim.packages.${system}.gigvim-differ;
  gigvim-gigvim-marker = inputs.gigvim.packages.${system}.gigvim-marker;
  gigvim-marker = inputs.gigvim.packages.${system}.marker;
}
