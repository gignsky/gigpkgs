{
  id = "2026-07-16-gignews-post";
  num = 17;
  date = "2026-07-16";
  timestamp = "2026-07-16T19:42:46Z";
  message = ''
    Author news with `gignews post` (gignews 0.1.2)

    Writing a news entry no longer means copying boilerplate. From a gigpkgs
    checkout:

      gignews post my-slug        # scaffold news/entries/<date>-my-slug.nix, open $EDITOR
      gignews post my-slug -m ".."  # fill the body non-interactively (for scripts/tools)

    New entries are stamped with the next `num` and a precise UTC `timestamp`, so
    same-day entries now sort by when they were written (shown in your local time).
    The entries directory is found via $GIGNEWS_ENTRIES_DIR, --entries-dir, or by
    walking up from the current directory.
  '';
}
