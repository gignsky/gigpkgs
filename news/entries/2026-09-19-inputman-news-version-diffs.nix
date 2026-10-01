{
  id = "2026-09-19-inputman-news-version-diffs";
  num = 41;
  date = "2026-09-19";
  timestamp = "2026-09-19T00:00:00Z";
  message = ''
    inputMan news entries now show what changed

    Previously an `inputman update` entry only said the input had been
    refreshed. Entries now carry a diff: the locked revision and upstream
    date on either side of the update, plus a version bump for every
    package the input exposes that declares one. A single version change
    is promoted into the entry title, e.g.

      Updated flake input 'roll-flow' (0.2.3 -> 0.2.4)

    `install` entries record the revision and versions the input entered
    the repo at, and `remove` entries record the revision it was dropped
    at, so updates always have a baseline to diff against.
  '';
}
