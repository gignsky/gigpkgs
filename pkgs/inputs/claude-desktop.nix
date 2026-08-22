# gigpkgs inputMan: managed input
{ inputs, system }:
{
  claude-desktop = inputs.claude-desktop.packages.${system}.claude-desktop;
  claude-desktop-with-fhs = inputs.claude-desktop.packages.${system}.claude-desktop-with-fhs;
  claude-desktop-patchy-cnb = inputs.claude-desktop.packages.${system}.patchy-cnb;
}