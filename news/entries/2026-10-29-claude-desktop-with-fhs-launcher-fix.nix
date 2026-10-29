{
  id = "2026-10-29-claude-desktop-with-fhs-launcher-fix";
  num = 61;
  date = "2026-10-29";
  timestamp = "2026-10-29T20:23:35Z";
  message = ''
    `claude-desktop-with-fhs` now launches inside the FHS env from app launchers

    Upstream's `claude-desktop-with-fhs` only wrapped `bin/claude-desktop`; its
    `.desktop` entry still pointed at the unwrapped binary. Launching Claude from
    a menu/launcher (or the "New Chat" / "New Claude Code Session" actions)
    therefore skipped the FHS env, and dynamically linked binaries such as MCP
    servers and npx/uvx tools failed to run.

    gigpkgs now rewrites every `Exec=` line in the desktop entry to use the FHS
    wrapper. If you use the plain `claude-desktop` package and need dynamically
    linked binaries to work, switch to `pkgs.claude-desktop-with-fhs`.
  '';
}
