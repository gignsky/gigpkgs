{
  id = "2026-07-16-sequential-ids";
  num = 16;
  date = "2026-07-16";
  message = ''
    Mark news read by number (gignews 0.1.1)

    News entries now carry a short, stable number shown in listings. You can
    mark an item read (or view it) by that number instead of typing the full id:

      gignews list        # each entry shows a #number
      gignews read 3      # mark entry #3 read
      gignews read 3 4 5  # mark several at once (space- or comma-separated)
      gignews read <id>   # the full string id still works too
      gignews show 3      # view entry #3

    Numbers are stable — each entry keeps its number for good. When adding a new
    entry, give it the next unused `num`.
  '';
}
