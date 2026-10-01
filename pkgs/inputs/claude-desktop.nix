# gigpkgs inputMan: managed input
{ inputs, system }:
{
  claude-desktop = inputs.claude-desktop.packages.${system}.claude-desktop;
  claude-desktop-claude-desktop-shell = inputs.claude-desktop.packages.${system}.claude-desktop-shell;
  claude-desktop-claude-desktop-with-fhs = inputs.claude-desktop.packages.${system}.claude-desktop-with-fhs;
}