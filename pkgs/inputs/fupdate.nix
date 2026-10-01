# gigpkgs inputMan: managed input
{ inputs, system }:
{
  fupdate = inputs.fupdate.packages.${system}.default;
}
