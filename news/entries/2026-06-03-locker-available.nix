{
  id = "2026-06-03-locker-available";
  num = 1;
  date = "2026-06-03";
  message = ''
    locker — Interactive flake lock updater

    The locker package provides an interactive way to update flake.lock
    entries with preview and confirmation.

    Usage: locker              # interactive mode
           locker -y           # auto-confirm all updates
           locker <input-name> # update specific input

    Available via: pkgs.locker
  '';
}
