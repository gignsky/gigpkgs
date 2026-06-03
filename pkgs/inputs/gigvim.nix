# Packages from gigvim input
{ inputs, system, ... }:
{
  gigvim = inputs.gigvim.packages.${system}.default or null;
}
